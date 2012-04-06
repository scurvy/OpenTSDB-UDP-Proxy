#!/bin/env ruby

require 'rubygems'
require 'memcached'
require 'eventmachine'
require 'socket'

# Address to listen on for the proxy. Listens on all addresses
# by default
PROXYLISTEN = '0.0.0.0'

# UDP port to listen on for proxy requests.
PROXYPORT = 11212 

# Memcache/couchbase servers to use
MEMCACHESERVER = ['memcache1.yourdomain.net:11211','memcache2.yourdomain.net:11211']

# Address of your OpenTSDB server instance
TSDBSERVER = 'opentsdb.yourdomain.net'

# TCP port of your OpenTSDB server instance
TSDBPORT = 4242

# How often to update OpenTSDB with data. In seconds.
TSDBTIMER = 10

# Dump the stats to a flat file? Either true or false.
# We read these values with OpenNMS, and it does alerting for us.
STATSDUMP = false

# Stats flat file location. STATSDUMP value must be true for this to
# have any effect.
STATSFILE = '/tmp/counterstats'

$metrics = {}
$sets = []

module MemcacheFwd
  def post_init
    puts "Server started"
  end

  def receive_data(data)
    if data.length > 0 && data.split(' ')
      request = data.split(' ')
      if request.length == 2 #we have a global counter
        action = request[0].downcase
        key = request[1] + ":host=unknown"
        $metrics[key] = 'metric'
        begin
          case action
            when 'increment'
              $cache.increment(key)
            when 'decrement'
              $cache.decrement(key)
            else
              puts 'invalid action'
              send_data('invalid action\n')
          end
        rescue Memcached::NotFound
          $cache.set(key,'0',ttl=0,marshall=false)
        end
      else #we have tags or a set operation
        action = request[0].downcase
        begin
          case action
            when 'increment'
              key = request[1] + ':' + data.split(' ',3)[2].tr(' ', ':')
              $metrics[key] = 'metric'
              $cache.increment(key)
            when 'decrement'
              key = request[1] + ':' + data.split(' ',3)[2].tr(' ', ':')
              $metrics[key] = 'metric'
              $cache.decrement(key)
            when 'set'
              now = Time.now.to_i
              key = request[1]
              val = request[2]
              tags = data.split(' ',4)[3]
              $sets.push([key,now,val,tags])
            else
              puts 'invalid action'
              send_data('invalid action\n')
          end
        rescue Memcached::NotFound
          $cache.set(key,'0',ttl=0,marshall=false)
        end
      end
    else
      send_data('send some data homey!\n')
    end
  end
end

opentsdbfwd = proc do
  f = File.new(STATSFILE,'w') if STATSDUMP
  tsdbserver = TCPSocket.open(TSDBSERVER, TSDBPORT)
  $metrics.each do |k,v|
    value = $cache.get(k,marshall=false)
    arrmetric = k.split(':',2)
    metric = arrmetric[0]
    tags = arrmetric[1].tr(':', ' ')
    tsdbserver.puts "put #{metric} #{Time.now.to_i} #{value} #{tags}\r\n"
    f.puts "#{k}: #{value}" if STATSDUMP
  end
  tsdbserver.close
  f.close if STATSDUMP
end

opentsdbset = proc do
  tsdbserver = TCPSocket.open(TSDBSERVER, TSDBPORT)
  while $sets.length > 0
    entry = $sets.pop
    tsdbserver.puts "put #{entry[0]} #{entry[1]} #{entry[2]} #{entry[3]}\r\n"
  end
  tsdbserver.close
end

EventMachine::run do
  $cache = Memcached.new( MEMCACHESERVER,
                          :use_udp => false,
                          :binary_protocol => true,
                          :hash => :none,
                          :retry_timeout => 10,
                          :server_failure_limit => 3 )
  EventMachine::open_datagram_socket(PROXYLISTEN, PROXYPORT, MemcacheFwd)
  EventMachine::add_periodic_timer(TSDBTIMER,opentsdbfwd)
  EventMachine::add_periodic_timer(TSDBTIMER,opentsdbset)
end
