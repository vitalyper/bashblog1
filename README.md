Bash remains a ubiquitous Swiss army knife for sysadmins, devops and occasionally other backend programming folk. Here is even [Lisp interpreter](https://github.com/alandipert/gherkin) written in it. As in any programming endeavour implementation ranges from spaghetti code to library like buildings blocks. Below I am sharing two examples of latter in attempt to reinforce that any language supporting functions (albeit, quite limited in bash) should take advantage of low level abstractions combined together to achieve reuse and speed of development.

### Wait Until Condition
Recently on devops short-term stunt I had to automate creation of AWS instance and running chef bootstrap on it using [Amazon Command Line API](http://aws.amazon.com/cli/). The wrinkle was that spawning an instance in AWS EC2 is implemented in async poll fashion.

1. **aws ec2 run-instances <args>** -> instance_id
2. Seconds later <instance_id> becomes live and <IP> address is assigned to it (IP can be obtained via a separate **describe_instances <args>** call)
3. More seconds later the instance is booted and sshd is running

So, steps 2 and 3 call for an abstraction, which given some timeout could report success so next step can proceed with minimal delay and no user input. It would be nice if we could also provide an estimate for the first wait and then half it until we reach max timeout.

```bash
# Waits until condition specified by 4+ args returns success (0)
# Arg1: max seconds to wait
# Arg2: nbr of seconds to wait first time
# Arg3: min seconds to wait
# Arg4+: condition and its args
function wait_until_condition {
    local max=$1
    local cur_wait=$2
    local min_wait=$3
    shift 3

    local wait_cnt=0

    while true; do
        sleep "${cur_wait}s"
        # It is important here that condition command DOES NOT do any output
        # So discard STDOUT
        $("$@" > /dev/null)
        if [ "$?" -eq 0 ] ; then
            return 0
        else
            wait_cnt=$(echo "$wait_cnt + $cur_wait" | bc)
            if [ "$wait_cnt" -gt "$max" ] ; then
                echo "Maximum of $max secs is reached for <$@> to execute successfully." && return 1
            fi
            cur_wait=$(div_by_2 $cur_wait $min_wait)
        fi
    done
}
```

Above we utilise bash support for varied function parameters, function return values, dynamic evaluation and rudimentary (but sufficient) integer arithmetic. See [lib.sh](lib.sh) for more info.

Now, we can create another function **create_ec2_instance** which abstracts away AWS EC2 instance creation and could be used as a building block of yet another higher level sequence.

```bash
# Create ec2 instance, wait for it to reach ssh connectable state and return instance_id
# Arg 1: ec2 cli region (eu-west-1,...)
# Arg 2: name for node
# Arg 3: AMI ID
# Arg 4: ec2 instance type
# Arg 5: ec2 key name
function create_ec2_instance {
    local region=$1
    local node_name=$2
    local image_id=$3
    local instance_type=$4
    local key_name=$5

    local tmp_file=$(mktemp -t "${node_name}XXXXXXXX")

    aws ec2 run-instances --region $region --image-id $image_id --count 1 --instance-type $instance_type --key-name $key_name --security-groups default > $tmp_file \
        || return $?

    local inst_id=$(cat $tmp_file \
        | jq '.Instances[] | {InstanceId}' \
        | grep InstanceId | grep -v null | cut -d ':' -f2 | tr -d ' "') \
        || return $?

    (wait_until_condition 180 20 3 is_instance_running $region $inst_id) || return $?

    # Now IPs are assigned
    local inst_info=$(get_instance_info $region $inst_id '{PublicDnsName}')
    local public_dns=$(get_key_value "$inst_info" 'PublicDnsName')

    local iden_file="${key_name}.pem"

    (wait_until_condition 90 10 3 is_sshd_up $iden_file $os_user $public_dns) || return $?

    # Return instance id
    echo $inst_id
}
```

If you would like to play with, and see debug output from, **wait_until_condition** (requires Bash 4.x) you can:

```bash
set -x
source lib.sh
wait_until_condition 16 8 2 [ $(( $(date +%s) % 2 )) -eq 0 ] && echo "epoch secs is even" >&2
set +x
```

### Parallel Exec
Now imagine that your are working on distributed application platform with few web servers, few app servers, database, etc. and you would like to build an environment in AWS EC2 with N instances. Wouldn't be nice to parallelize the env creation so max time is the time of the longest task? Well, bash has a job control so let's build a parallel execution function. Passing all arguments would be a nuisance so let's write them to a temp file and pass it in instead.

```bash
# Runs commands from specified file in parallel
# Arg1: file to read lines from
# Arg2: delete file in arg 1: y|Y|yes|Yes|t|T|true|True
function parallel_exec {
    local input_file=$1
    local do_delete=$2

    [ -e $input_file -a -r $input_file -a -s $input_file ] || (echo "can not read $input_file" >&2; return 1;)

    local -A pids_by_idx
    local -A outs_by_pid

    while read -r line
    do
        local md5seed=$(get_md5 "$line")
        local outf=$(mktemp -t ${md5seed}XXX)

        $(eval $line &> ${outf}) &
        local lpid=$!

        pids_by_idx[$lpid]=$lpid
        outs_by_pid[$lpid]=$outf
    done < "$input_file"

    local -i complete_count=0
    local -i success_count=0
    while true
    do
        for pid in "${!pids_by_idx[@]}"
        do
            if kill -0 "$pid" 2>/dev/null; then
                :
            elif wait "$pid"; then
                success_count=$(echo "$success_count + 1" | bc)
                complete_count=$(echo "$complete_count + 1" | bc)
                unset pids_by_idx[$pid]

                # output to stderr, although stdout would be better but conflicts with standard bash function echo return
                cat ${outs_by_pid[$pid]} >&2
            else
                complete_count=$(echo "$complete_count + 1" | bc)
                unset pids_by_idx[$pid]

                cat ${outs_by_pid[$pid]} >&2
            fi
        done

        if [ "$complete_count" -eq "${#outs_by_pid[@]}" ] ; then
            break;
        fi

        # Be a good citizen and yield to prevent busy waiting.
        # Could be further customized with a default and an arg.
        sleep 1s
    done

    for outf in "${outs_by_pid[@]}"
    do
        rm -f $outf
    done

    if [[ "$do_delete" =~ ^y|Y|t|T ]] ; then
        rm -f $input_file
    fi

    if [ "$success_count" -ne "${#outs_by_pid[@]}" ] ; then
        return $(echo "${#outs_by_pid[@]} - $success_count" | bc)
    else
        return 0
    fi
}
```

Some of the bash features used here are: associative arrays, local integer variables and built-in regex matching. The most interesting twist is with checking status of a background job. First, we interrogate each PID with signal 0. If return is non-zero - the job is finished and we can retrieve it's exit status with **wait**. Then, we simply do a bookkeeping and return success if all jobs finished OK.

Here is how you can play with **parallel_exec**
```bash
source lib.sh
tmpf='input.txt'
echo "date; echo \"running job 1\"; sleep 2s; date;" >> $tmpf
echo "date; echo \"running job 2\"; sleep 5s; date;" >> $tmpf
echo "date; echo \"running job 3\"; sleep 4s; date;" >> $tmpf
date; echo; parallel_exec $tmpf; echo; date;
```

Some parting thoughts. When facing with bash scripting tasks we can build a library of reusable functions but a million dollar question is when to stop. Shell scripting becomes awkward on more complex and involved problems. But, as I hopefully shown, we don't have to settle for spaghetti scripts and should kick some good mileage out of old good BASH.
