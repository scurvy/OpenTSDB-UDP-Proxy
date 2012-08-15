#!/bin/env ruby

require 'rubygems'
require 'redis'
require 'eventmachine'
require 'socket'

# Address to listen on for the proxy. Listens on all addresses
# by default
PROXYLISTEN = '0.0.0.0'

# UDP port to listen on for proxy requests.
PROXYPORT = 11212

# Redis server to use
REDISSERVER = 'yourredisserverhere'

# Redis port to use
REDISPORT = '6379'

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

module RedisFwd
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
        tries = 0
        begin
          case action
            when 'increment'
              $cache.incr(key)
            when 'decrement'
              $cache.decr(key)
            else
              puts 'invalid action'
              send_data('invalid action\n')
          end
        rescue e
          puts e.to_s
        end
      else #we have tags or a set operation
        action = request[0].downcase
        case action
          when 'increment'
            key = request[1] + ':' + data.split(' ',3)[2].tr(' ', ':')
            $metrics[key] = 'metric'
            begin
              $cache.incr(key)
            rescue e
              puts e.to_s
            end
          when 'decrement'
            key = request[1] + ':' + data.split(' ',3)[2].tr(' ', ':')
            $metrics[key] = 'metric'
            begin
              $cache.decr(key)
            rescue e
              puts e.to_s
            end
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
    value = $cache.get(k)
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
  $cache = Redis.new( :host => REDISSERVER,
                      :port => REDISPORT )
  EventMachine::open_datagram_socket(PROXYLISTEN, PROXYPORT, RedisFwd)
  EventMachine::add_periodic_timer(TSDBTIMER,opentsdbfwd)
  EventMachine::add_periodic_timer(TSDBTIMER,opentsdbset)
end
