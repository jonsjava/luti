#!/usr/bin/env bash
luti_help(){
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --help                          Show this help message and exit"
    echo "  -f=FILE, --config=FILE              Specify config file (default: config)"
    echo "  -i=INSTANCE, --instance=INSTANCE    Specify instance (example: https://lemmy.world)"
    echo "  -u=USERNAME, --username=USERNAME    Specify username"
    echo "  -p=PASSWORD, --password=PASSWORD    Specify password"
    echo "  -m, --mfa                           Specify if you use MFA"
	echo "  -r=REFRESH, --refresh=REFRESH       Specify refresh interval in seconds (default: 60)"
}
# Baseline code was shamelessly stolen from https://lemmy.world/post/1180324
API="api/v3"
set +H
REFRESH_INTERVAL=60
CONFIG_FILE="config"
for i in "$@"
do
  case $i in
    -h|--help)
	  luti_help
	  exit 0
	;;
    --config=*|-f=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
	--instance=*|-i=*)
	  my_instance="${i#*=}"
	  INSTANCE_SET=true
	  shift
	;;
	--username=*|-u=*)
	  my_username="${i#*=}"
	  USERNAME_SET=true
	  shift
	;;
	--password=*|-p=*)
	  my_password="${i#*=}"
	  PASSWORD_SET=true
	  shift
	;;
	--mfa|-m)
	  USE_MFA=true
	  shift
	;;
	--refresh|-r)
	  REFRESH_INTERVAL="${i#*=}"
	  shift
	;;
	*)
	  echo "Unknown option: $i"
	  exit 1
	;;
  esac
done

if [ "$INSTANCE_SET" == true ] && [ "$USERNAME_SET" == true ] && [ "$PASSWORD_SET" == true ]; then
	echo "Config values passed as arguments.  Bypassing config file."
	sleep 3
else
	if [ ! -f $CONFIG_FILE ]; then
		echo "First time run. Setting up config file '$CONFIG_FILE'.  Please edit config file and run again."
		echo '# CHANGE THESE VALUES
my_instance=""			# e.g. https://lemmy.world
my_username=""			                    # e.g. freamon
my_password=""		                        # e.g. hunter2
USE_MFA=false                                # true or false depending on if you use MFA' > $CONFIG_FILE
		exit 0
	else
		source config
	fi
fi
number_regular_expression='^[0-9]+$'

source functions
system_check
# check if MFA token provided and if it's a number
if [ "$USE_MFA" == true ]; then
	read -p "Enter MFA Token: " MFA_TOKEN
	if [[ ! $MFA_TOKEN =~ $number_regular_expression ]]; then
		echo "invalid MFA token"
		exit 1
	fi
fi
new_jwt=$(login)
$USER_ID=$(get_user_id "someuser@not.areallemmy.instance")
$COMMUNITY_ID=$(get_community_id "somecommunitynameonmyinstance")

# the following would ban someone from a community for a day with a message
#ban_user_from_community $USER_ID $COMMUNITY_ID "We don't like your kind" "1"
# the following would permaban someone from a community with a message
perm_ban_user_from_community $USER_ID $COMMUNITY_ID "We don't like your kind"
