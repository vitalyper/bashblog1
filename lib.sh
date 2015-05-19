# Halfs number until min
# Arg1: numeric value, i.e. 40
# Arg2: min value, i.e. 5
function div_by_2 {
    if [ "$1" -gt "$2" ] ; then
        echo "$1 / 2" | bc
    else
        echo "$2"
    fi
}

# Waits until condition specified by 4+ args returns non-empty string
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


# Gets md5 in portable (Linux and OS X (Darvin) only) way
# Arg1: string to hash
function get_md5 {
    local os_name=$(uname)

    if [ $os_name == 'Linux' ] ; then
        # by default md5sum outputs mode and file, so get md5 only
        echo "$1" | md5sum | cut -d ' ' -f 1
    elif [ $os_name == 'Darwin' ] ; then
        echo "$1" | md5
    else
        echo "OS $os_name is not supported"
        return 1
    fi
}

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
