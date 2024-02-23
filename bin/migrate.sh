#!/bin/bash
namespace="default"
input="input"
output="output"

POSITIONAL=()
while (( $# > 0 )); do
    case "${1}" in
        -n|--namespace)
        numOfArgs=1 # number of switch arguments
        if (( $# < numOfArgs + 1 )); then
            shift $#
        else
            namespace=${2}
            shift $((numOfArgs + 1)) # shift 'numOfArgs + 1' to bypass switch and its value
        fi
        ;;
        -i|--input)
        numOfArgs=1 # number of switch arguments
        if (( $# < numOfArgs + 1 )); then
            shift $#
        else
            input=${2}
            shift $((numOfArgs + 1)) # shift 'numOfArgs + 1' to bypass switch and its value
        fi
        ;;
        -o|--output)
        numOfArgs=1 # number of switch arguments
        if (( $# < numOfArgs + 1 )); then
            shift $#
        else
            output=${2}
            shift $((numOfArgs + 1)) # shift 'numOfArgs + 1' to bypass switch and its value
        fi
        ;;
        *) # unknown flag/switch
        POSITIONAL+=("${1}")

        shift
        ;;
    esac
done

set -- "${POSITIONAL[@]}" # restore positional params

./bin/pv-migrate migrate -i -s svc --log-level trace\
  --helm-set rsync.extraArgs="--partial --inplace --whole-file --exclude='Pal-LinuxServer.pak' --exclude='Pal/Binaries/Linux/*'" \
  --helm-set sshd.tolerations[0].key=scale.sealos.io/node \
  --helm-set sshd.tolerations[0].operator=Exists \
  --helm-set sshd.tolerations[0].effect=NoSchedule \
  --helm-set rsync.tolerations[0].key=scale.sealos.io/node \
  --helm-set rsync.tolerations[0].operator=Exists \
  --helm-set rsync.tolerations[0].effect=NoSchedule \
  --source-namespace "$namespace" \
  --dest-namespace "$namespace" \
  "$input" "$output"