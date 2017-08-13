#!/bin/bash
# A basic tool for running scripts on multiple remote hosts using local inventory files.
set -e -f -o pipefail

function usage() {
  	echo "shout - run scripts on multiple remote hosts - [version 0.0.1]"
    echo 'Example: shout [-m host_alias] [-g group_file_path] [-c command] script'
    printf "\t%s\n" "-g    Add group file to list of hosts"
    printf "\t%s\n" "-m    Add single host to list of hosts"
    printf "\t%s\n" "-t    Copy over file/folder using scp"
    printf "\t%s\n" "-c    Run command on list of hosts"
    printf "\t%s\n" "-p    Run playbook file"
    printf "\t%s\n" "-s    Execute using sudo"
    printf "\t%s\n" "-z    Clear temp directory"
    printf "\t%s\n" "-h    Prints help"
    exit 1
}

function clear_tmp_directory() {
  rm -rf .shout/runs && echo "Temp directory removed"
  exit 0
}

######
## Read options
######
machine_params=()
group_params=()
template_params=()
command_params=()
playbook_params=()

command_prefix=''

while getopts ":m:g:t:c:p:hzs" opt; do
  case $opt in
    h)
      usage
      ;;
    m)
      machine_params+=("$OPTARG")
      ;;
    g)
      group_params+=("$OPTARG")
      ;;
    t) 
      template_params+=("$OPTARG")
      ;;
    c) 
      command_params+=("$OPTARG")
      ;;
    p) 
      playbook_params+=("$OPTARG")
      ;;
    z)
      clear_tmp_directory
      ;;
    s)
      command_prefix='sudo '
      ;;
    *)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

script_params=("$@")

if [[ -z $machine_params && -z $group_params && -z $playbook_params && -z $template_params ]]; then
  usage
fi

if [[ -z $command_params && -z $script_params && -z $playbook_params ]]; then
  usage
fi

######
## Script logic
######
_RID=$(date +%Y%m%d_%H%M%S)
_TEMP_DIR=".shout/runs/${_RID}"
mkdir -p "$_TEMP_DIR/logs"

function log() {
  local now=$(date +%Y-%m-%dT%H:%M:%S)
  echo "${now} $1"
}

function stage_group_file() {
  # log "reading file $1"
  grep -o '^[^#]*' $1 | awk 'NF' | while read line; do 
    local alias=$(echo $line | cut -d ' ' -f 1 | xargs)
    local connect_string=$(echo $line | cut -d ' ' -f 2- | xargs)
    echo "$alias $connect_string" >> $_TEMP_DIR/staging_hosts
  done
}

function stage_group_machines() {
  for i in $group_params; do 
    stage_group_file $i
  done
}

function stage_hosts_if_requested() {
  grep -o '^[^#]*' $1 | awk 'NF' | while read line; do 
    local alias=$(echo $line | cut -d ' ' -f 1 | xargs)
    for host in ${machine_params[@]}; do
      if [ "$host" == "$alias" ]; then
        local connect_string=$(echo $line | cut -d ' ' -f 2- | xargs)
        # log "staging host $alias $connect_string"
        echo "$alias $connect_string" >> $_TEMP_DIR/staging_hosts
      fi
    done
  done
}

function stage_machines() {
  find . -name 'hosts' | while read file; do
    stage_hosts_if_requested $file
  done
  find . -name '*.hosts' | while read file; do
    stage_hosts_if_requested $file
  done
  # TODO stage those not found by alias
}

function remove_tmp_dir() {
  if [[ $_TEMP_DIR == *".shout/runs"* ]]; then
    rm -rf $_TEMP_DIR
  fi
}

function validate_staged_machines() {
  cat $_TEMP_DIR/staging_hosts | sort | uniq > $_TEMP_DIR/target_hosts
}

function info_execution_plan() {
  echo "============"
  echo "Local log dir: $_TEMP_DIR/"
  echo "Remote tmp dir: ~/.shout/${_RID}/"
  echo "Staged hosts:"
  cat $_TEMP_DIR/target_hosts | while read line; do
    echo "  Host: $line"
  done
  echo "Staged templates:"
  for template in "${template_params[@]}"; do
    echo "  Template: $template"
  done
  echo "Staged commands:"
  for command in "${command_params[@]}"; do
    echo "  Command: $command"
  done
  echo "Staged scripts:"
  for script in "${script_params[@]}"; do
    echo "  Script: $script"
  done
  echo "============"
}

function scp_file() {
  local alias=$1
  local scp_connect_string=$2
  local hostname_part=$3
  local template=$4

  # Copy over file to tmp location
  local tmp_path="~/.shout/${_RID}/tmp/$template"
  echo "scp -r $scp_connect_string $template $hostname_part:$tmp_path" >> $_TEMP_DIR/logs/$alias.log
  scp -p -q -r $scp_connect_string $template $hostname_part:$tmp_path 2>&1 | tee -a $_TEMP_DIR/logs/$alias.log

  # Put file in the right location, might involve sudo
  local template_parts=(${template/:/ })
  local template_parts_length=${#template_parts[@]}
  local from_location=''
  local to_location=''
  if (( $template_parts_length == 2 )); then
    from_location="${template_parts[0]}"
    to_location="${template_parts[1]}"
  else
    from_location="${template_parts[0]}"
    to_location="~/.shout/${_RID}/${template_parts[0]}"
  fi

  # See if we need to apply sudo
  echo "ssh -n $connect_string /bin/bash -c '${command_prefix}mv --strip-trailing-slashes $tmp_path $to_location'" >> $_TEMP_DIR/logs/$alias.log
  ssh -q -n $connect_string "/bin/bash -c '${command_prefix}mv --strip-trailing-slashes $tmp_path $to_location'" 2>&1 | tee -a $_TEMP_DIR/logs/$alias.log | while read output; do
    echo "$alias: $output"
  done
}

function execute_script() {
  local alias=$1
  local connect_string=$2
  local scp_connect_string=$3
  local hostname_part=$4
  local script=$5
  echo "scp -p -q $scp_connect_string $script $hostname_part:~/.shout/${_RID}/$script" >> $_TEMP_DIR/logs/$alias.log
  scp -p -q $scp_connect_string $script $hostname_part:~/.shout/${_RID}/$script 2>&1 | tee -a $_TEMP_DIR/logs/$alias.log
  echo "Executing ~/.shout/${_RID}/$script on $alias"
  echo "ssh -n $connect_string /bin/bash -c 'cd ~/.shout/${_RID} && chmod +x ./$script && ${command_prefix}./$script'" >> $_TEMP_DIR/logs/$alias.log
  ssh -q -n $connect_string "/bin/bash -c 'cd ~/.shout/${_RID} && chmod +x ./$script && ${command_prefix}./$script'" 2>&1 | tee -a $_TEMP_DIR/logs/$alias.log | while read output; do
    echo "$alias: $output"
  done
}

function execute_all() {
  # Loop through hosts
  # TODO add support for GNU parallel here
  cat $_TEMP_DIR/target_hosts | while read line; do
    local alias=$(echo $line | cut -d ' ' -f 1)
    local optional_connect_string=$(echo $line | cut -d ' ' -f 2-)
    local connect_string=''
    if [[ -z $optional_connect_string ]]; then
      connect_string=$alias
    else
      connect_string=$optional_connect_string
    fi

    # Build SCP connect string
    local connect_parts=(${connect_string/ / })
    local connect_parts_length=${#connect_parts[@]}
    local scp_connect_string=''
    local last_index=$(( $connect_parts_length - 1 ))
    local hostname_part="${connect_parts[$last_index]}"
    for (( i=0; i<=$(( $connect_parts_length - 2 )); i++ )); do 
      if [ "${connect_parts[$i]}" == "-p" ]; then
        scp_connect_string+='-P '
      else 
        scp_connect_string+="${connect_parts[$i]} "
      fi
    done
    
    # Create temp run folder on the remote host
    if [[ ! -z $template_params || ! -z $script_params ]]; then
      echo "ssh -n $connect_string /bin/bash -c 'mkdir -p ~/.shout/${_RID}/tmp'" >> $_TEMP_DIR/logs/$alias.log
      ssh -q -n $connect_string "/bin/bash -c 'mkdir -p ~/.shout/${_RID}/tmp'" 2>&1 | tee -a $_TEMP_DIR/logs/$alias.log
    fi

    # Copy over template files and folders
    for template in "${template_params[@]}"; do
      scp_file "$alias" "$scp_connect_string" "$hostname_part" "$template"
    done

    # Run commands
    for command in "${command_params[@]}"; do
      echo "ssh -n $connect_string /bin/bash -c '${command_prefix}$command'" >> $_TEMP_DIR/logs/$alias.log
      ssh -q -n $connect_string "/bin/bash -c '${command_prefix}$command'" 2>&1 | tee -a $_TEMP_DIR/logs/$alias.log | while read output; do
        echo "$alias: $output"
      done
    done

    # Execute scripts
    for script in "${script_params[@]}"; do
      execute_script "$alias" "$connect_string" "$scp_connect_string" "$hostname_part" "$script"
    done
  done
}

function execute_playbook() {
  local playbook_path=$1
  local playbook_arguments=$(grep -o '^[^#]*' $playbook_path | awk 'NF' | tr '\n' ' ')
  local playbook_command="$0 $playbook_arguments"
  echo "$playbook_command"
  eval "$playbook_command"
}

function info_staged_playbooks() {
  echo "============"
  echo "Staged playbooks:"
  for playbook in "${playbook_params[@]}"; do
    echo "  Playbook: $playbook"
  done
  echo "============"
}

function execute() {
  # Read group files by path
  stage_group_machines

  # Load additional machines, if required
  local machines_requested=0
  for i in "${machine_params[@]}"; do
    machines_requested=1
  done
  if (( $machines_requested == 1 )); then
    stage_machines
  fi

  # Keep unique list of hosts
  validate_staged_machines
  
  # Show execution plan
  info_execution_plan

  # Execute on the requested paths
  execute_all
}

function main() {
  # Playbook flow
  # If playbooks are requested, they bypass main logic and call a sub-shout
  local playbook_params_length=${#playbook_params[@]}
  if (( $playbook_params_length > 0 )); then 
    info_staged_playbooks
    for playbook_path in "${playbook_params[@]}"; do
      execute_playbook $playbook_path
    done 
    return
  fi

  # Normal flow
  execute
}

main

exit 0
# printf "%s\n" "${machine_params[@]}"