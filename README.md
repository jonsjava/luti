# LUTI - Lemmy User Terminal Interface
Luti is a simplistic interface that allows you to interact with your instance as a user, moderator, or administrator.

This project is under development, and at this point just will allow you to see reports that moderators have (comment and post).

The end goal of this project is to allow full BASH interaction with Lemmy instances, from reading posts through moderation and administration.

### Current usage:

```bash
Usage: ./luti.sh [OPTIONS]
Options:
  -h, --help                          Show this help message and exit
  -f=FILE, --config=FILE              Specify config file (default: config)
  -i=INSTANCE, --instance=INSTANCE    Specify instance (example: https://lemmy.world)
  -u=USERNAME, --username=USERNAME    Specify username
  -p=PASSWORD, --password=PASSWORD    Specify password
  -m, --mfa                           Specify if you use MFA
  -r=REFRESH, --refresh=REFRESH       Specify refresh interval in seconds (default: 60)
```