# bash completion for pv-migrate                           -*- shell-script -*-

__pv-migrate_debug()
{
    if [[ -n ${BASH_COMP_DEBUG_FILE:-} ]]; then
        echo "$*" >> "${BASH_COMP_DEBUG_FILE}"
    fi
}

# Homebrew on Macs have version 1.3 of bash-completion which doesn't include
# _init_completion. This is a very minimal version of that function.
__pv-migrate_init_completion()
{
    COMPREPLY=()
    _get_comp_words_by_ref "$@" cur prev words cword
}

__pv-migrate_index_of_word()
{
    local w word=$1
    shift
    index=0
    for w in "$@"; do
        [[ $w = "$word" ]] && return
        index=$((index+1))
    done
    index=-1
}

__pv-migrate_contains_word()
{
    local w word=$1; shift
    for w in "$@"; do
        [[ $w = "$word" ]] && return
    done
    return 1
}

__pv-migrate_handle_go_custom_completion()
{
    __pv-migrate_debug "${FUNCNAME[0]}: cur is ${cur}, words[*] is ${words[*]}, #words[@] is ${#words[@]}"

    local shellCompDirectiveError=1
    local shellCompDirectiveNoSpace=2
    local shellCompDirectiveNoFileComp=4
    local shellCompDirectiveFilterFileExt=8
    local shellCompDirectiveFilterDirs=16

    local out requestComp lastParam lastChar comp directive args

    # Prepare the command to request completions for the program.
    # Calling ${words[0]} instead of directly pv-migrate allows to handle aliases
    args=("${words[@]:1}")
    # Disable ActiveHelp which is not supported for bash completion v1
    requestComp="PV_MIGRATE_ACTIVE_HELP=0 ${words[0]} __completeNoDesc ${args[*]}"

    lastParam=${words[$((${#words[@]}-1))]}
    lastChar=${lastParam:$((${#lastParam}-1)):1}
    __pv-migrate_debug "${FUNCNAME[0]}: lastParam ${lastParam}, lastChar ${lastChar}"

    if [ -z "${cur}" ] && [ "${lastChar}" != "=" ]; then
        # If the last parameter is complete (there is a space following it)
        # We add an extra empty parameter so we can indicate this to the go method.
        __pv-migrate_debug "${FUNCNAME[0]}: Adding extra empty parameter"
        requestComp="${requestComp} \"\""
    fi

    __pv-migrate_debug "${FUNCNAME[0]}: calling ${requestComp}"
    # Use eval to handle any environment variables and such
    out=$(eval "${requestComp}" 2>/dev/null)

    # Extract the directive integer at the very end of the output following a colon (:)
    directive=${out##*:}
    # Remove the directive
    out=${out%:*}
    if [ "${directive}" = "${out}" ]; then
        # There is not directive specified
        directive=0
    fi
    __pv-migrate_debug "${FUNCNAME[0]}: the completion directive is: ${directive}"
    __pv-migrate_debug "${FUNCNAME[0]}: the completions are: ${out}"

    if [ $((directive & shellCompDirectiveError)) -ne 0 ]; then
        # Error code.  No completion.
        __pv-migrate_debug "${FUNCNAME[0]}: received error from custom completion go code"
        return
    else
        if [ $((directive & shellCompDirectiveNoSpace)) -ne 0 ]; then
            if [[ $(type -t compopt) = "builtin" ]]; then
                __pv-migrate_debug "${FUNCNAME[0]}: activating no space"
                compopt -o nospace
            fi
        fi
        if [ $((directive & shellCompDirectiveNoFileComp)) -ne 0 ]; then
            if [[ $(type -t compopt) = "builtin" ]]; then
                __pv-migrate_debug "${FUNCNAME[0]}: activating no file completion"
                compopt +o default
            fi
        fi
    fi

    if [ $((directive & shellCompDirectiveFilterFileExt)) -ne 0 ]; then
        # File extension filtering
        local fullFilter filter filteringCmd
        # Do not use quotes around the $out variable or else newline
        # characters will be kept.
        for filter in ${out}; do
            fullFilter+="$filter|"
        done

        filteringCmd="_filedir $fullFilter"
        __pv-migrate_debug "File filtering command: $filteringCmd"
        $filteringCmd
    elif [ $((directive & shellCompDirectiveFilterDirs)) -ne 0 ]; then
        # File completion for directories only
        local subdir
        # Use printf to strip any trailing newline
        subdir=$(printf "%s" "${out}")
        if [ -n "$subdir" ]; then
            __pv-migrate_debug "Listing directories in $subdir"
            __pv-migrate_handle_subdirs_in_dir_flag "$subdir"
        else
            __pv-migrate_debug "Listing directories in ."
            _filedir -d
        fi
    else
        while IFS='' read -r comp; do
            COMPREPLY+=("$comp")
        done < <(compgen -W "${out}" -- "$cur")
    fi
}

__pv-migrate_handle_reply()
{
    __pv-migrate_debug "${FUNCNAME[0]}"
    local comp
    case $cur in
        -*)
            if [[ $(type -t compopt) = "builtin" ]]; then
                compopt -o nospace
            fi
            local allflags
            if [ ${#must_have_one_flag[@]} -ne 0 ]; then
                allflags=("${must_have_one_flag[@]}")
            else
                allflags=("${flags[*]} ${two_word_flags[*]}")
            fi
            while IFS='' read -r comp; do
                COMPREPLY+=("$comp")
            done < <(compgen -W "${allflags[*]}" -- "$cur")
            if [[ $(type -t compopt) = "builtin" ]]; then
                [[ "${COMPREPLY[0]}" == *= ]] || compopt +o nospace
            fi

            # complete after --flag=abc
            if [[ $cur == *=* ]]; then
                if [[ $(type -t compopt) = "builtin" ]]; then
                    compopt +o nospace
                fi

                local index flag
                flag="${cur%=*}"
                __pv-migrate_index_of_word "${flag}" "${flags_with_completion[@]}"
                COMPREPLY=()
                if [[ ${index} -ge 0 ]]; then
                    PREFIX=""
                    cur="${cur#*=}"
                    ${flags_completion[${index}]}
                    if [ -n "${ZSH_VERSION:-}" ]; then
                        # zsh completion needs --flag= prefix
                        eval "COMPREPLY=( \"\${COMPREPLY[@]/#/${flag}=}\" )"
                    fi
                fi
            fi

            if [[ -z "${flag_parsing_disabled}" ]]; then
                # If flag parsing is enabled, we have completed the flags and can return.
                # If flag parsing is disabled, we may not know all (or any) of the flags, so we fallthrough
                # to possibly call handle_go_custom_completion.
                return 0;
            fi
            ;;
    esac

    # check if we are handling a flag with special work handling
    local index
    __pv-migrate_index_of_word "${prev}" "${flags_with_completion[@]}"
    if [[ ${index} -ge 0 ]]; then
        ${flags_completion[${index}]}
        return
    fi

    # we are parsing a flag and don't have a special handler, no completion
    if [[ ${cur} != "${words[cword]}" ]]; then
        return
    fi

    local completions
    completions=("${commands[@]}")
    if [[ ${#must_have_one_noun[@]} -ne 0 ]]; then
        completions+=("${must_have_one_noun[@]}")
    elif [[ -n "${has_completion_function}" ]]; then
        # if a go completion function is provided, defer to that function
        __pv-migrate_handle_go_custom_completion
    fi
    if [[ ${#must_have_one_flag[@]} -ne 0 ]]; then
        completions+=("${must_have_one_flag[@]}")
    fi
    while IFS='' read -r comp; do
        COMPREPLY+=("$comp")
    done < <(compgen -W "${completions[*]}" -- "$cur")

    if [[ ${#COMPREPLY[@]} -eq 0 && ${#noun_aliases[@]} -gt 0 && ${#must_have_one_noun[@]} -ne 0 ]]; then
        while IFS='' read -r comp; do
            COMPREPLY+=("$comp")
        done < <(compgen -W "${noun_aliases[*]}" -- "$cur")
    fi

    if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
        if declare -F __pv-migrate_custom_func >/dev/null; then
            # try command name qualified custom func
            __pv-migrate_custom_func
        else
            # otherwise fall back to unqualified for compatibility
            declare -F __custom_func >/dev/null && __custom_func
        fi
    fi

    # available in bash-completion >= 2, not always present on macOS
    if declare -F __ltrim_colon_completions >/dev/null; then
        __ltrim_colon_completions "$cur"
    fi

    # If there is only 1 completion and it is a flag with an = it will be completed
    # but we don't want a space after the =
    if [[ "${#COMPREPLY[@]}" -eq "1" ]] && [[ $(type -t compopt) = "builtin" ]] && [[ "${COMPREPLY[0]}" == --*= ]]; then
       compopt -o nospace
    fi
}

# The arguments should be in the form "ext1|ext2|extn"
__pv-migrate_handle_filename_extension_flag()
{
    local ext="$1"
    _filedir "@(${ext})"
}

__pv-migrate_handle_subdirs_in_dir_flag()
{
    local dir="$1"
    pushd "${dir}" >/dev/null 2>&1 && _filedir -d && popd >/dev/null 2>&1 || return
}

__pv-migrate_handle_flag()
{
    __pv-migrate_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"

    # if a command required a flag, and we found it, unset must_have_one_flag()
    local flagname=${words[c]}
    local flagvalue=""
    # if the word contained an =
    if [[ ${words[c]} == *"="* ]]; then
        flagvalue=${flagname#*=} # take in as flagvalue after the =
        flagname=${flagname%=*} # strip everything after the =
        flagname="${flagname}=" # but put the = back
    fi
    __pv-migrate_debug "${FUNCNAME[0]}: looking for ${flagname}"
    if __pv-migrate_contains_word "${flagname}" "${must_have_one_flag[@]}"; then
        must_have_one_flag=()
    fi

    # if you set a flag which only applies to this command, don't show subcommands
    if __pv-migrate_contains_word "${flagname}" "${local_nonpersistent_flags[@]}"; then
      commands=()
    fi

    # keep flag value with flagname as flaghash
    # flaghash variable is an associative array which is only supported in bash > 3.
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        if [ -n "${flagvalue}" ] ; then
            flaghash[${flagname}]=${flagvalue}
        elif [ -n "${words[ $((c+1)) ]}" ] ; then
            flaghash[${flagname}]=${words[ $((c+1)) ]}
        else
            flaghash[${flagname}]="true" # pad "true" for bool flag
        fi
    fi

    # skip the argument to a two word flag
    if [[ ${words[c]} != *"="* ]] && __pv-migrate_contains_word "${words[c]}" "${two_word_flags[@]}"; then
        __pv-migrate_debug "${FUNCNAME[0]}: found a flag ${words[c]}, skip the next argument"
        c=$((c+1))
        # if we are looking for a flags value, don't show commands
        if [[ $c -eq $cword ]]; then
            commands=()
        fi
    fi

    c=$((c+1))

}

__pv-migrate_handle_noun()
{
    __pv-migrate_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"

    if __pv-migrate_contains_word "${words[c]}" "${must_have_one_noun[@]}"; then
        must_have_one_noun=()
    elif __pv-migrate_contains_word "${words[c]}" "${noun_aliases[@]}"; then
        must_have_one_noun=()
    fi

    nouns+=("${words[c]}")
    c=$((c+1))
}

__pv-migrate_handle_command()
{
    __pv-migrate_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"

    local next_command
    if [[ -n ${last_command} ]]; then
        next_command="_${last_command}_${words[c]//:/__}"
    else
        if [[ $c -eq 0 ]]; then
            next_command="_pv-migrate_root_command"
        else
            next_command="_${words[c]//:/__}"
        fi
    fi
    c=$((c+1))
    __pv-migrate_debug "${FUNCNAME[0]}: looking for ${next_command}"
    declare -F "$next_command" >/dev/null && $next_command
}

__pv-migrate_handle_word()
{
    if [[ $c -ge $cword ]]; then
        __pv-migrate_handle_reply
        return
    fi
    __pv-migrate_debug "${FUNCNAME[0]}: c is $c words[c] is ${words[c]}"
    if [[ "${words[c]}" == -* ]]; then
        __pv-migrate_handle_flag
    elif __pv-migrate_contains_word "${words[c]}" "${commands[@]}"; then
        __pv-migrate_handle_command
    elif [[ $c -eq 0 ]]; then
        __pv-migrate_handle_command
    elif __pv-migrate_contains_word "${words[c]}" "${command_aliases[@]}"; then
        # aliashash variable is an associative array which is only supported in bash > 3.
        if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
            words[c]=${aliashash[${words[c]}]}
            __pv-migrate_handle_command
        else
            __pv-migrate_handle_noun
        fi
    else
        __pv-migrate_handle_noun
    fi
    __pv-migrate_handle_word
}

_pv-migrate_completion()
{
    last_command="pv-migrate_completion"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--help")
    flags+=("-h")
    local_nonpersistent_flags+=("--help")
    local_nonpersistent_flags+=("-h")
    flags+=("--log-format=")
    two_word_flags+=("--log-format")
    flags_with_completion+=("--log-format")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    flags+=("--log-level=")
    two_word_flags+=("--log-level")
    flags_with_completion+=("--log-level")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")

    must_have_one_flag=()
    must_have_one_noun=()
    must_have_one_noun+=("bash")
    must_have_one_noun+=("fish")
    must_have_one_noun+=("powershell")
    must_have_one_noun+=("zsh")
    noun_aliases=()
}

_pv-migrate_help()
{
    last_command="pv-migrate_help"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--log-format=")
    two_word_flags+=("--log-format")
    flags_with_completion+=("--log-format")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    flags+=("--log-level=")
    two_word_flags+=("--log-level")
    flags_with_completion+=("--log-level")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")

    must_have_one_flag=()
    must_have_one_noun=()
    has_completion_function=1
    noun_aliases=()
}

_pv-migrate_migrate()
{
    last_command="pv-migrate_migrate"

    command_aliases=()

    commands=()

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--dest-context=")
    two_word_flags+=("--dest-context")
    flags_with_completion+=("--dest-context")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-C")
    flags_with_completion+=("-C")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--dest-context")
    local_nonpersistent_flags+=("--dest-context=")
    local_nonpersistent_flags+=("-C")
    flags+=("--dest-delete-extraneous-files")
    flags+=("-d")
    local_nonpersistent_flags+=("--dest-delete-extraneous-files")
    local_nonpersistent_flags+=("-d")
    flags+=("--dest-host-override=")
    two_word_flags+=("--dest-host-override")
    two_word_flags+=("-H")
    local_nonpersistent_flags+=("--dest-host-override")
    local_nonpersistent_flags+=("--dest-host-override=")
    local_nonpersistent_flags+=("-H")
    flags+=("--dest-kubeconfig=")
    two_word_flags+=("--dest-kubeconfig")
    two_word_flags+=("-K")
    local_nonpersistent_flags+=("--dest-kubeconfig")
    local_nonpersistent_flags+=("--dest-kubeconfig=")
    local_nonpersistent_flags+=("-K")
    flags+=("--dest-namespace=")
    two_word_flags+=("--dest-namespace")
    flags_with_completion+=("--dest-namespace")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-N")
    flags_with_completion+=("-N")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--dest-namespace")
    local_nonpersistent_flags+=("--dest-namespace=")
    local_nonpersistent_flags+=("-N")
    flags+=("--dest-path=")
    two_word_flags+=("--dest-path")
    flags_with_completion+=("--dest-path")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-P")
    flags_with_completion+=("-P")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--dest-path")
    local_nonpersistent_flags+=("--dest-path=")
    local_nonpersistent_flags+=("-P")
    flags+=("--helm-set=")
    two_word_flags+=("--helm-set")
    flags_with_completion+=("--helm-set")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--helm-set")
    local_nonpersistent_flags+=("--helm-set=")
    flags+=("--helm-set-file=")
    two_word_flags+=("--helm-set-file")
    flags_with_completion+=("--helm-set-file")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--helm-set-file")
    local_nonpersistent_flags+=("--helm-set-file=")
    flags+=("--helm-set-string=")
    two_word_flags+=("--helm-set-string")
    flags_with_completion+=("--helm-set-string")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--helm-set-string")
    local_nonpersistent_flags+=("--helm-set-string=")
    flags+=("--helm-timeout=")
    two_word_flags+=("--helm-timeout")
    two_word_flags+=("-t")
    local_nonpersistent_flags+=("--helm-timeout")
    local_nonpersistent_flags+=("--helm-timeout=")
    local_nonpersistent_flags+=("-t")
    flags+=("--helm-values=")
    two_word_flags+=("--helm-values")
    two_word_flags+=("-f")
    local_nonpersistent_flags+=("--helm-values")
    local_nonpersistent_flags+=("--helm-values=")
    local_nonpersistent_flags+=("-f")
    flags+=("--ignore-mounted")
    flags+=("-i")
    local_nonpersistent_flags+=("--ignore-mounted")
    local_nonpersistent_flags+=("-i")
    flags+=("--lbsvc-timeout=")
    two_word_flags+=("--lbsvc-timeout")
    local_nonpersistent_flags+=("--lbsvc-timeout")
    local_nonpersistent_flags+=("--lbsvc-timeout=")
    flags+=("--no-chown")
    flags+=("-o")
    local_nonpersistent_flags+=("--no-chown")
    local_nonpersistent_flags+=("-o")
    flags+=("--no-progress-bar")
    flags+=("-b")
    local_nonpersistent_flags+=("--no-progress-bar")
    local_nonpersistent_flags+=("-b")
    flags+=("--skip-cleanup")
    flags+=("-x")
    local_nonpersistent_flags+=("--skip-cleanup")
    local_nonpersistent_flags+=("-x")
    flags+=("--source-context=")
    two_word_flags+=("--source-context")
    flags_with_completion+=("--source-context")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-c")
    flags_with_completion+=("-c")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--source-context")
    local_nonpersistent_flags+=("--source-context=")
    local_nonpersistent_flags+=("-c")
    flags+=("--source-kubeconfig=")
    two_word_flags+=("--source-kubeconfig")
    two_word_flags+=("-k")
    local_nonpersistent_flags+=("--source-kubeconfig")
    local_nonpersistent_flags+=("--source-kubeconfig=")
    local_nonpersistent_flags+=("-k")
    flags+=("--source-mount-read-only")
    flags+=("-R")
    local_nonpersistent_flags+=("--source-mount-read-only")
    local_nonpersistent_flags+=("-R")
    flags+=("--source-namespace=")
    two_word_flags+=("--source-namespace")
    flags_with_completion+=("--source-namespace")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-n")
    flags_with_completion+=("-n")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--source-namespace")
    local_nonpersistent_flags+=("--source-namespace=")
    local_nonpersistent_flags+=("-n")
    flags+=("--source-path=")
    two_word_flags+=("--source-path")
    flags_with_completion+=("--source-path")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-p")
    flags_with_completion+=("-p")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--source-path")
    local_nonpersistent_flags+=("--source-path=")
    local_nonpersistent_flags+=("-p")
    flags+=("--ssh-key-algorithm=")
    two_word_flags+=("--ssh-key-algorithm")
    flags_with_completion+=("--ssh-key-algorithm")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-a")
    flags_with_completion+=("-a")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--ssh-key-algorithm")
    local_nonpersistent_flags+=("--ssh-key-algorithm=")
    local_nonpersistent_flags+=("-a")
    flags+=("--strategies=")
    two_word_flags+=("--strategies")
    flags_with_completion+=("--strategies")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    two_word_flags+=("-s")
    flags_with_completion+=("-s")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    local_nonpersistent_flags+=("--strategies")
    local_nonpersistent_flags+=("--strategies=")
    local_nonpersistent_flags+=("-s")
    flags+=("--log-format=")
    two_word_flags+=("--log-format")
    flags_with_completion+=("--log-format")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    flags+=("--log-level=")
    two_word_flags+=("--log-level")
    flags_with_completion+=("--log-level")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")

    must_have_one_flag=()
    must_have_one_noun=()
    has_completion_function=1
    noun_aliases=()
}

_pv-migrate_root_command()
{
    last_command="pv-migrate"

    command_aliases=()

    commands=()
    commands+=("completion")
    commands+=("help")
    commands+=("migrate")
    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]:-}" -gt 3 ]]; then
        command_aliases+=("m")
        aliashash["m"]="migrate"
    fi

    flags=()
    two_word_flags=()
    local_nonpersistent_flags=()
    flags_with_completion=()
    flags_completion=()

    flags+=("--log-format=")
    two_word_flags+=("--log-format")
    flags_with_completion+=("--log-format")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")
    flags+=("--log-level=")
    two_word_flags+=("--log-level")
    flags_with_completion+=("--log-level")
    flags_completion+=("__pv-migrate_handle_go_custom_completion")

    must_have_one_flag=()
    must_have_one_noun=()
    noun_aliases=()
}

__start_pv-migrate()
{
    local cur prev words cword split
    declare -A flaghash 2>/dev/null || :
    declare -A aliashash 2>/dev/null || :
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion -s || return
    else
        __pv-migrate_init_completion -n "=" || return
    fi

    local c=0
    local flag_parsing_disabled=
    local flags=()
    local two_word_flags=()
    local local_nonpersistent_flags=()
    local flags_with_completion=()
    local flags_completion=()
    local commands=("pv-migrate")
    local command_aliases=()
    local must_have_one_flag=()
    local must_have_one_noun=()
    local has_completion_function=""
    local last_command=""
    local nouns=()
    local noun_aliases=()

    __pv-migrate_handle_word
}

if [[ $(type -t compopt) = "builtin" ]]; then
    complete -o default -F __start_pv-migrate pv-migrate
else
    complete -o default -o nospace -F __start_pv-migrate pv-migrate
fi

# ex: ts=4 sw=4 et filetype=sh
