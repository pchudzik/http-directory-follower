#!/bin/bash

#
# Source:   https://gist.github.com/bsdcon/7224196
# Original: https://gist.github.com/habibutsu/5420781
# Modified by Adrian Penisoara  << ady+tailurl (at) bsdconsultants.com >>
#
# Last update: 8 Aug 2014
#

usage() {
    cat >&2 <<EOF

Usage: $0 [ -u <username> [ -p {<password>|-} ] [ -j <password file> ]] [-{f|F} [ -s <update interval> ] [ -m <multiplier> [ -x <max interval> ]] [ -t <interval> ]] <url to monitor>

    -u    specify user for authentication ; can be set in TAILURL_USER variable
    -p    specify password for authentication; if "-" then password will be read
          from stdin
    -j    specify a password file (which contains the password) instead of
          quoting on command line ; can be set in TAILURL_PWFILE variable
    -f    follow any appended data (but bail out on errors)
    -F    follow any changes to the file (will restart from beginning upon
          resource being truncated) ; if present twice then any curl errors will
          be ignored and we will forcibly keep polling the resource
    -s    specify interval for update checks (seconds, default 1 sec) ; can be
          set in TAILURL_SLEEP variable
    -m    apply the specified multiplier for every "idle" update interval
    -x    limit to the specified maximum idle update interval (seconds, defaults
          to 1 hour) ; can be set in TAILURL_MAXSLEEP variable
    -t    timestamp with date when resource becomes idle for specified interval
          (seconds)
    <url> the URL towards the resource to be tracked; needs to be quoted when
          unsafe characters are present

EOF
    exit 1
}

curl_error() {
    if [ $retry != ALWAYS ]; then
        echo "CURL exited with error code $1 -- aborting" >&2
        exit $2
    fi

    printf "==> [$(date)] CURL exit code: $1 <==  \r" >&2
    return $1  # propagate back error code for optional looping
}

http_error() {
    if [ $retry = ALWAYS ]; then
        printf "==> [$(date)] HTTP code: $2 ($1) <==  \r" >&2
        return 1  # for optional looping
    fi

    cat >&2 <<EOF

HTTP ERROR: $1 (code $2)

EOF
    [ -n "$3" ] && cat >&2 <<EOF
- - - - - - - - - - - - - - - - -
$3
EOF
    exit 2
}

[ -n "$TAILURL_USER" ] && user="$TAILURL_USER"
[ -n "$TAILURL_PWFILE" ] && pwfile="$TAILURL_PWFILE"

follow=NO
retry=NO
sleep=${TAILURL_SLEEP:-1}
multiply=1
maxsleep=${TAILURL_MAXSLEEP:-3600}
while getopts ":fFu:p:j:s:m:x:t:" arg; do
  case $arg in
     f) follow=YES
        ;;

     F) follow=YES
        case "$retry" in
            NO)  retry=YES
                 ;;
            YES) retry=ALWAYS
                 ;;
        esac
        ;;

     u) user=$OPTARG
        ;;

     p) if [ "$OPTARG" = "-" ]; then
            # we will trigger reading the password later
            pass=""
        else
            pass=$OPTARG
        fi
        pwfile=""
        ;;

     j) pwfile=$OPTARG
        [ -r $pwfile ] || { echo "Password file $pwfile unreadable" ; exit 3; }
        ;;

     s) sleep=$OPTARG
        ;;

     m) multiply=$OPTARG
        ;;

     x) maxsleep=$OPTARG
        ;;

     t) tstamp=$OPTARG
        ;;

     *) echo "Syntax error"
        usage
        ;;
  esac
done
shift $((OPTIND-1))

if [ -z "$1" ]; then
   usage
fi

CURL_CMD="curl -k --url \"$1\" -s"

# Trick CURL into fetching the user/password on stdin instead of passing as args
if [ -n "$user" ]; then
    if [ -z "$pwfile" -a -z "$pass" ]; then
        # Prompt on STDERR to avoid interfering with pipe operations
        echo -n "Password for user $user: " >&2
        stty -echo
        read pass
        stty echo
    fi

    CURL_FLAGS="-K -"         # this will make curl read config entries on stdin
    if [ -n "$pwfile" ]; then
        pwgen="(echo -n \"user = $user:\"; cat $pwfile)"
    else
        pwgen="echo \"user = $user:$pass\""
    fi
    CURL_CMD="$pwgen | $CURL_CMD $CURL_FLAGS"
fi

STATUS=$(eval $CURL_CMD -I) || curl_error $?
STATUS_CODE=$(echo -e "${STATUS}"|egrep "HTTP/1.1 [0-9]+"|egrep -o "[0-9]{3}")
SIZE=$(echo -e "${STATUS}"|egrep "Content-Length: [0-9]+"|egrep -o "[0-9]+")

if [ "${STATUS_CODE:0:1}xx" != "2xx" ]; then
    http_error "Resource unreachable or does not support HTTP 1.1 protocol" \
                "$STATUS_CODE" "$STATUS"
fi

if [ -z "$SIZE" ]; then
    http_error "Resource does not support size inquiry" "$STATUS_CODE" "$STATUS"
fi

START_SIZE=$(expr ${SIZE:-0} - 1000)
if [ -z "$START_SIZE" ] || [ $START_SIZE -lt 0 ]; then
    START_SIZE=0
fi

# idle cycles counter
icounter=0
interval=$sleep
while [ true ]
do
    if [ -n "$tstamp" ] && [ $icounter -gt $tstamp ]; then
        printf "\n[ $(date) ]\n\n" >&2
        # Disable counter until next update
        icounter=-1
    fi

    # Wait for update check, unless first run
    [ $icounter -ne 0 ] && sleep $interval
    # Apply update interval factor and max limit
    [ $icounter -ne 0 ] && interval=$(expr $interval \* $multiply) && \
        [ $interval -gt $maxsleep ] && interval=$maxsleep
    # Finally, increase idle update counter, unless disabled
    [ $icounter -ge 0 ] && icounter=$(expr $icounter + $interval / $multiply)

    STATUS=$(eval $CURL_CMD -I --range $START_SIZE-) || curl_error $? || continue
    STATUS_CODE=$(echo -e "${STATUS}"|egrep "HTTP/1.1 [0-9]+"|egrep -o "[0-9]{3}")
    CONTENT_LENGTH=$(echo -e "${STATUS}"|egrep "Content-Length: [0-9]+"|egrep -o "[0-9]+")
    if [ $STATUS_CODE == 206 ]; then
        SIZE=$(expr $START_SIZE + $CONTENT_LENGTH)
        eval $CURL_CMD --range $START_SIZE-$SIZE || curl_error $? || continue
        START_SIZE=$SIZE
        icounter=1
        interval=$sleep
    elif [ "${STATUS_CODE:0:3}" = "416" ]; then
        if [ $retry != NO ]; then
            STATUS=$(eval $CURL_CMD -I) || curl_error $? || continue
            newsize=$(echo -e "${STATUS}"|egrep "Content-Length: [0-9]+"|egrep -o "[0-9]+")
            if [ $newsize -lt $SIZE ]; then
                echo "==> File has been truncated -- restarting from 0" >&2
                START_SIZE=0
                continue
            fi
        fi
    else
        http_error "Resource no longer reachable" "$STATUS_CODE" "$STATUS"
    fi
    [ $follow = YES ] || break
done
