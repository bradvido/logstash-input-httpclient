# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "net/http"

# Query a http server with GET requests at a regular interval. 
#
#[%hardbreaks]
# HTTP GET requests are performed using the provided url (which may contain URL parameters).
# The HTTP Response body will be added to "message" after being decoded by the provided codec.
# There is an additional header named `X-Logstash-Avg-Queue-Secs` added to each HTTP request. This is the
# average seconds it took for the past 20 events to be accepted by Logstash's bounded input queue. 
# The HTTP server could use this as a indication of how many events the Logstash instance is able to process (throughput).


class LogStash::Inputs::HttpClient < LogStash::Inputs::Base
  config_name "httpclient"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain" 

  #[%hardbreaks]
  # The full url to execute GET requests on. 
  # It may contain URL parameters (you are responsible for URL encoding them)
  # e.g. `https://mywebservice.int/`
  # e.g. `http://mywebservice.int?queue=logstash_events&numevents=10`
  #
  # IMPORTANT: make sure you end with a slash (if not using url params). `http://mywebservice.int` is not valid, it must be `http://myswebservice.int/`
  # todo: auto-append slash if user forgets
  config :url, :validate => :string, :required => true

  # Set how frequently we should query the url for messages
  #
  # The default, `10`, means send a message every 10 seconds.
  config :interval, :validate => :number, :default => 10
  
  # The name of the object that http response meta-data (headers, response code, etc) should be added to.
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
      while true
        begin
          sleepIval = @interval
          begin
            http_start = Time.now
            request = Net::HTTP::Get.new(@uri.request_uri)
            request ["X-Logstash-Avg-Queue-Secs"] = arr_avg(queue_times, 20, 3)
            response = http.request request  # Net::HTTPResponse object
            http_elapsed = Time.now - http_start
          rescue => e
            @logger.warn("Http request failed, will retry", :exception => e)
            @logger.warn(e.backtrace)
            sleep(sleepIval)
            retry
          end

          if response["X-More-Events-Available"] == "true"
            sleepIval = 0 #don't wait if the server indicated there are more events ready now
          end

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
            queue_elapsed = Time.now - queue_start
            queue_times.push queue_elapsed
          end
        ensure
          sleep(@interval)
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