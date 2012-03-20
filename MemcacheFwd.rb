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

$metrics = {}

module MemcacheFwd
  def post_init
    puts "Server started"
  end

  def receive_data(data)
    if data.length > 0 && data.split(' ')
      request = data.split(' ')
      action = request[0].downcase
      key = request[1]
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
    else
      send_data('send some data homey!\n')
    end
  end
end

opentsdbfwd = proc do
  tsdbserver = TCPSocket.open(TSDBSERVER, TSDBPORT)
  $metrics.each do |k,v|
    value = $cache.get(k,marshall=false)
    tsdbserver.puts "put #{k} #{Time.now.to_i} #{value} host=all\r\n"
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
end
