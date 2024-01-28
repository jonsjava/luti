#!/usr/bin/env bash

# Baseline code was shamelessly stolen from https://lemmy.world/post/1180324
API="api/v3"
set +H
if [ ! -f config ]; then
	echo "First time run. Setting up config file.  Please edit config file and run again."
	echo '# CHANGE THESE VALUES
my_instance="https://lemmy.world"			# e.g. https://feddit.nl
my_username=""			                    # e.g. freamon
my_password=""		                        # e.g. hunter2
USE_MFA=false                                # true or false depending on if you use MFA' > config
	exit 0
fi
number_regular_expression='^[0-9]+$'
source config
source functions
# check if MFA token provided and if it's a number
if [ $USE_MFA = true ]; then
	read -p "Enter MFA Token: " MFA_TOKEN
	if [[ ! $MFA_TOKEN =~ $number_regular_expression ]]; then
		echo "invalid MFA token"
		exit 1
	fi
fi

jwt=$(login)


system_check
while [ 1 ]; do
	clear
	get_mod_reports
	sleep 60
done
