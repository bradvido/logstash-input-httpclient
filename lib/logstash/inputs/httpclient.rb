# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "net/http"

# Query a http server with GET requests at a regular interval. 
#
# HTTP GET requests are performed using the provided url (which may contain parameters).
# The HTTP Response body will be added to "message" after being decoded by the provided codec.
# There is an additional header named `X-Logstash-Avg-Queue-Secs` added to each HTTP request. This is the
# average seconds it took for the past 20 events to be accepted by Logstash's input queue. 
# The HTTP server could use this as a indication of how many events the client is able to process without blocking.


class LogStash::Inputs::HttpClient < LogStash::Inputs::Base
  config_name "httpclient"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain" 

  # The message string to use in the event.
  config :url, :validate => :string, :required => true

  # Set how frequently we should query the url for messages
  #
  # The default, `1`, means send a message every second.
  config :interval, :validate => :number, :default => 1
  
  # The name of the object that http response meta-data (headerd, timing, etc) should be added to.
  config :response_object_name, :validate => :string, :default => "http_response"
  
  # Should the http headers be added to the `response_object_name`?
  #
  # If true, there will be a "headers" with all the response headers/values.
  config :include_response_headers, :validate => :boolean, :default => false
  
  # Should the http response code be added to the `response_object_name`?
  #
  # If true, there will be a "code" with all the response headers/values.
  config :include_response_code, :validate => :boolean, :default => true
  
  # Should the http request elapsed time be added to the `response_object_name`?
  #
  # If true, there will be a "took_secs" with the time it took for the http request to complete
  config :include_http_request_time, :validate => :boolean, :default => true
  
  public
  def register
    @uri = URI(@url)
  end # def register

  def run(queue)
    queue_times = Array.new #track an average of how long it's taking to queue events into logstash
    #::start creates a connection to the HTTP server and keeps it alive for the duration
    Net::HTTP.start @uri.host, @uri.port, :use_ssl => @uri.scheme == 'https' do |http|
      Stud.interval(@interval) do
        begin
          http_start = Time.now
          request = Net::HTTP::Get.new(@uri.path)          
          request ["X-Logstash-Avg-Queue-Secs"] = arr_avg(queue_times, 20, 3)
          response = http.request request  # Net::HTTPResponse object
          http_elapsed = Time.now - http_start
        rescue => e
          @logger.warn("Http request failed, will retry", :exception => e)
          @logger.warn(e.backtrace)
          sleep(@interval)
          retry
        end
        #event = LogStash::Event.new("message" => response.body)
        @codec.decode(response.body) do |event|
          event[@response_object_name] = {}
          if @include_response_headers 
            event[@response_object_name]["headers"] = response
          end
          if @include_response_code 
            event[@response_object_name]["code"] = response.code
          end
          if @include_http_request_time 
            event[@response_object_name]["took_secs"] = http_elapsed
          end
          decorate(event)
          queue_start = Time.now
          queue << event
          queue_elapsed = Time.now - http_start
          queue_times.push queue_elapsed
        end
      end #interval loop
    end #HTTP keepalive
  end # def run
  
  def arr_avg(arr,cutoff,precision)
    if(arr.size == 0)
      return 0
    end
    if(arr.size > cutoff)
      arr.drop(arr.length-cutoff) #removes from beginning of array
    end
    #get the average
    (arr.inject{ |sum, el| sum + el }.to_f / arr.size).round(precision)
  end
end # class LogStash::Inputs::Example