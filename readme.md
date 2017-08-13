# Shout
A basic tool for running scripts on multiple remote hosts for when other automation tools are overkill

## Usage
```
shout [-m host_alias] [-g group_file_path] [-c command] script
	-g    Add group file to list of hosts
	-m    Add single host to list of hosts
	-t    Copy over file/folder using scp
	-c    Run command on list of hosts
	-p    Run playbook file
	-z    Clear temp directory
	-h    Prints help
```

## Install
```
# Download shout.sh to some directory
sudo cp shout.sh /bin/shout
sudo chmod +x /bin/shout
# Open a new shell
```

## Finding hosts
When using -m aliases, shout will search all hosts & *.hosts files from the current directory for these aliases.  

When using only -g paths, only those files will be loaded.

### Individual hosts
These hosts are searched through all available host file.  
If not found, ssh config alias fallback is done.
```
shout -m host1 -m host2 script.sh
```

### Group files
Group together hosts.  
```
shout -g path/to/groupfile -g otherfile script.sh
```

### Hosts file structure
```
# alias [ssh-connect-info]
# example:
web    ubuntu@webmachine
mysql  -p 23 ubuntu@webmachine
```

## Copying files
Files are copied before running commands

### Copy to run directory
Here the file will be available on the same path as the script executes remotely.
```
shout -t local_file -g web_nodes
```

### Copy to a location
By using the : syntax you can copy a file to a specific location.
```
shout -t local_file:/var/www/html/filename -g web_nodes
```

## Commands
Commands are executed before scripts
```
shout -m host1 -g group1 -c 'df -h' -c 'whoami'
```

## Scripts
```
shout -m host1 -g group1 script.sh
```

## Playbooks
Playbook allow you to store a configuration for reuse.

### Usage
```
shout -p first_playbook_file [-p second_playbook_file] ...
```

### Playbook content
Playbooks are just commandline arguments in a file. identical how you would pass them directly to shout.   
```
-t hello.conf
-g groups/vagrants.hosts 
-c 'whoami' 
echo.sh
```

## Internal flow
1.  shout will first create a temp dir on each remote host ~/.shout/
2.  templates and scripts are copied to a run specific temp dir ~/.shout/$runid
3.  scripts and commands are executed from the temp dir
4.  all host output is available locally in .shout/runs/$id/logs

## TODO
- machine selection: fallback to alias when hostname not found
- playbooks: support multiple commands in single playbook
- readme: wget/curl install example
- tests
