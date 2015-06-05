# Logstash HTTP Client Input Plugin

This is a plugin for [Logstash](https://github.com/elasticsearch/logstash).

It is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it however you want in whatever way.

## Documentation

This plugin will open up a http keep-alive connection to any http server and periodically execute GET requests. The response body will be added to the `message` field of the logstash event.

This plugin also adds a `X-Logstash-Avg-Queue-Secs` header to every GET request. This indicates the average amount of "wait time" an event is waiting to be added to logstash's intenal bounded/blocking input queue. The server could use this value to determine how many events to send to logstash based on the throughput/wait time.

## Installing
`{logstash_dir}/bin/plugin install logstash-input-httpclient`

## Need Help?

Need help? Try #logstash on freenode IRC or the logstash-users@googlegroups.com mailing list.

## Contributing

All contributions are welcome: ideas, patches, documentation, bug reports, complaints, and even something you drew up on a napkin.

Programming is not a required skill. Whatever you've seen about open source and maintainers or community members  saying "send patches or die" - you will not see that here.

It is more important to the community that you are able to contribute.

For more information about contributing, see the [CONTRIBUTING](https://github.com/elasticsearch/logstash/blob/master/CONTRIBUTING.md) file.
