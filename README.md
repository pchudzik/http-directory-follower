Short info
==========
Fetch directory content (based on apache mod_dir). Finds first|last file matching pattern.
Executes tailurl (https://gist.github.com/bsdcon/7224196) on this file.
When newer file is found then kills previous watch and starts new watch on newer|older file.

Options
=======
```
  Usage: index [options] <pattern> <url>

  Options:

    -h, --help                 output usage information
    -u, --user [login]         user name for authentication
    -p, --password [password]  password for authentication
    -s, --scan [interval]      scan interval in seconds
    -r, --refresh [interval]   index refresh in seconds
    -o, --order [order]        files order [asc|desc]
```

Other
=====
* Will accept all self-signed stuff
* Will stop watching process when index can not be accessed
* In case of error will reprint all file content from remote host
* tailurl.sh source - https://gist.github.com/bsdcon/7224196
* following file content will be print to stdout. Diagnostics messages are print to stderr
