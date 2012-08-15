OpenTSDB UDP Proxy
==================

In short, this Ruby script will accept OpenTSDB counter/gauge commands via UDP, then send the updated value to OpenTSDB via TCP. This is because OpenTSDB doesn't have UDP support, nor native support for counters. If they add these features, *hint* we won't need this script.

Problem
-------

OpenTSDB is an powerful tool for tracking an extreme amount of data points in a very quick manner. The only problem with OpenTSDB is that it's just a time series database. It has no operators for increment or decrement. HBase (what OpenTSDB runs on) has these actors, but they're only available via TCP. Here at Weebly, we wanted a fast, lightweight, non-intrusive way to track a large number of counters and see them graphed in realtime. Also, no downsampling would be allowed. Full monty, full data set. For this reason, graphite, carbon, statsd, etc were all out. 

Our idea is to send simple updates from servers via UDP to a collector. For counter updates, the collector sends an increment or decrement operation to a Memcache or Couchbase server via persistent TCP connection. In a separate event loop, the proxy will query Memcache/Couchbase for the value of all counters it's seen, then send the data to OpenTSDB.

Set operations (for gauges) work in a similar manner, but they don't use Couchbase/Memcache. They're stored locally with a timestamp, then sent off to OpenTSDB at regular intervals. This avoids having us open and close a TCP socket frequently. In short, we're buffering the values in an array, then doing a buk update to OpenTSDB. Not rocket science.

Performance
-----------

I chose UDP because we wanted something lightweight and fast to send updates for. You don't need TCP here to say "Increase this counter by 1". In fact, you don't want this in something like a webapp -- even if you handle it outside of the render loop. You don't want to take down your website because your stats server went offline and every process was hung waiting for a TCP connect to time out. Also, you don't care about the reply from the server. Increment/decrement and be done. Wham bam, thank you ma'am.

Library
-------

There is no library. Just use a socket.

This is how easy it is to send a UDP datagram with Ruby:
        require 'socket'
	s = UDPSocket.new()
	s.send("increment yourawesomecounter",0,"yourproxyaddress",11212)

Why couchbase instead of redis, riak, etc ?
----------------------------------------------------

UPDATE: I added a redis version of the script named RedisFwd.rb. We ran into some weird issues with Couchbase where it would return KeyNotFound exceptions every now and then. That clashed with what we had to accomplish, so we changed our back-end of choice to redis. No more weird exceptions and the script is a little simpler since redis will automatically handle an increment operation on a key which doesn't exist (makes sense). This is what we were after all along, so switching made sense.

Memcache is easy, but it's not persistent nor does it handle failure well. Couchbase solves these problems. Add 2 servers and let it rip. Plus, the ASCII interface to memcache is super simple to use for troubleshooting. If you really don't care about stats persistence, you could use memcache instead of Couchbase or redis.

Overall, we'd recommend using the redis version of the script. Note that we ran into Couchbase problems when doing updates of about 2000-3000 per second. It was fine up to that point.

Why not directly track the counter in HBase?
--------------------------------------------

Yes, Hbase does have increment and decrement operators. However, it's Hbase and isn't as easy to write to as couchbase/memcached. Plus, we don't need the granularity of tracking every single value change of the counter.

Shut up already, how does this thing work?
------------------------------------------
 - Send your proxy a UDP datagram on port 11212 with the action and counter separated by a space. That's it. For example, "increment YourAwesomeCounter"
 - After receiving a datagram, the proxy will send the increment command to the couchbase/memcache server.
 - That's it. There is no reply.
 - In a separate event loop (every 10 seconds by default), the proxy will ask couchbase for the values of the counters it knows about (since startup). It will take that value and put it into OpenTSDB.

Do you support tags?
--------------------

I do now. If you don't send a tag with an increment or decrement operation, the proxy will add a default tag of host=all. It assumes that this is a global counter and that you don't care about tracking tags. If you want tag support, just append tags at the end of the operation.

Examples:

	increment yourCounter host=bob class=jameson
	decrement yourCounter class=emad cluster=rtb
	set yourCounter 100 host=etmaguire cluster=eflo

Is there a limit to the number of tags?
---------------------------------------

There might be one in HBase or OpenTSDB -- I think it's 8? Also, there's the maximum size of a UDP datagram. Don't go over that.

Do you support set (gauge) values now?
--------------------------------------

Yep. It's pretty simple. The only difference is that now you *must* add a tag to your request. No tag is no bueno.

Example:

	set yourCounter 100 host=etmaguire cluster=eflo

Can I use riak instead of couchbase?
---------------------------------------------

Sure. Go for it. I like riak. I know the Basho peeps. Give them some love. I only ask that you publish your stuff on the Githubs.

I built a high-frequency trading application off of this and it failed. You cost me millions.
---------------------------------------------------------------------------------------------

Sorry scro. No warranty here, neither expressed nor implied. Use at your own risk.
You should have hired some real programmers instead of just copying and pasting stuff off the Internet.

What are the requirements?
--------------------------

You'll need Ruby, the memcached or redis gem, and the eventmachine gem to run the script. You'll also need couchbase/redis setup along with OpenTSDB, Hbase, Hadoop, etc.

Your stuff is OK, but I want to modify it. Can I change it?
-----------------------------------------------------------

Sure! I only have eleventy billion other things to work on. I wrote this in 20 minutes.

Does it scale?
--------------

It scales better than it blends. Just add more proxy instances and point your clients at them (or use a UDP load balancer). The proxy has no local state -- Couchbase takes care of that. Eventmachine is pretty cool, so is UDP.

I don't see much exception handling in here. How do you keep it running?
------------------------------------------------------------------------

We use daemontools for stuff like this. You should, too. We don't care if it gets an unhandled exception. Daemontools will restart it. Big whoop.
