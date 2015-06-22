# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "net/http"

# Query a HTTP server with GET requests at a regular interval and process the events returned in the response body. 
#
#[%hardbreaks]
# HTTP GET requests are performed using the provided url (which may contain URL parameters).
# The HTTP Response body will be decoded by the provided coded and the events will be sent to logstash for filtering/output.
#
# HTTP Header Information (advanced use cases):
# There are several additional HTTP headers that can be useful if needed (otherwise they can be safely ignored):
#
# **Response Headers** (from the server)
# `X-More-Events-Available` If set to `true`, then there will be no wait time before the next HTTP GET Request is executed to get more events.
# `X-Messages-Batch-Id` Can be set to any value to identify this 'batch' of messages. The client will add a `X-Successful-Batch-Ids` header to the next request if this batch is successfully sent to logstash.
#
# **Request Headers** (these provide stats/info about the **previous** HTTP Request and the events processed from it)
# `X-Logstash-Num-Events` The number of events that were processed from the previous request
# `X-Logstash-Http-Request-Total-Secs` The time (in seconds) that it took for the HTTP Request to finish.
# `X-Logstash-Codec-Parse-Total-Secs`  The time (in seconds) that it took for the HTTP Response body to be parsed and decoded.
# `X-Logstash-Queue-Total-Secs` The time (in seconds) that it took to queue all of the events (logstash uses a fixed queue length of 20, so it blocks when full).
# `X-Successful-Batch-Ids` If the server provided a `X-Messages-Batch-Id` header in the previous request, that value is set in this header to acknowledge the messages were successfully sent to logstash.

class LogStash::Inputs::HttpClient < LogStash::Inputs::Base
	config_name "httpclient"

	# If undefined, Logstash will complain, even if codec is unused.
	default :codec, "plain" 

	#[%hardbreaks]
	# The full url to execute GET requests on. 
	# It may contain URL parameters (you are responsible for URL encoding them)
	# e.g. `https://mywebservice.mycompany.int/`
	# e.g. `http://mywebservice.mycompany.int?type=logstash_events&numevents=10`
	#
	config :url, :validate => :string, :required => true

	# Set how frequently we should query the url for messages
	#
	# The default, `10`, means execute a HTTP GET request every 10 seconds.
	# If the server adds a `X-More-Events-Available: true` header to the response, 
	#a new request will be executed immediately and this wait time will be ignored.
	config :interval, :validate => :number, :default => 10
	
	# If desired, meta-data about the HTTP Response can be included in the event.
	# This is the name of the object that http response meta-data (headers, response code, etc) will be added to.
	config :response_object_name, :validate => :string, :default => "http_response"
	
	# Should the http response headers be added to the `response_object_name`?
	#
	# If true, there will be a "headers" object with all the response headers/values.
	config :include_response_headers, :validate => :boolean, :default => false
	
	# Should the http response code be added to the `response_object_name`?
	#
	# If true, there will be a "code" with the response code.
	config :include_response_code, :validate => :boolean, :default => true
	
	# Should the http request elapsed time be added to the `response_object_name`?
	#
	# If true, there will be a "took_secs" with the time it took for the http request to complete
	config :include_http_request_time, :validate => :boolean, :default => true
	
	# The server should return this HTTP response code to indicate no messages were found/retuned.
	# When this status code is seen, the message body will not be processed or added to the Logstash input queue. 
	# Defaults to 204 (No Content)
	config :no_messages_response_code, :validate => :number, :default => 204
	
	public
	def register
		@uri = URI(@url)
	end # def register

	def run(queue)
		begin
			num_events = 0
			queue_time = nil #track an average of how long it's taking to queue events into logstash
			codec_parse_time = nil
			http_request_time = nil
			batch_id = nil
			
			@logger.debug("Initializing http connection")
			#Net::HTTP.start creates a connection to the HTTP server and keeps it alive for the duration. Throws an EOFError when connection breaks.
			Net::HTTP.start @uri.host, @uri.port, :use_ssl => @uri.scheme == 'https' do |http|
				while true
					http_start = Time.now
					sleepIval = @interval
					@logger.debug("Executing http get request: " + @uri.host + @uri.request_uri)
					request = Net::HTTP::Get.new(@uri.request_uri)
					
					#include stats from processing the previous batch as custom headers
					if num_events > 0 #0 if there wasn't anything processed in the last batch
						#send the times/stats (from the previous batch) as custom headers to the server 
						request ["X-Logstash-Num-Events"] = num_events
						request ["X-Logstash-Http-Request-Total-Secs"] = http_request_time
						request ["X-Logstash-Codec-Parse-Total-Secs"] = codec_parse_time
						request ["X-Logstash-Queue-Total-Secs"] = queue_time
					end
					if !batch_id.nil?
						request ["X-Successful-Batch-Ids"] = batch_id #send the previous successfully processed batch id so the server knows those messages were all processed by logstash
					end
					response = http.request request # execute GET request and return Net::HTTPResponse object
					if response["X-More-Events-Available"] == "true"
						sleepIval = 0 #don't wait if the server indicated there are more events ready now
					end
					batch_id = response["X-Messages-Batch-Id"] #save the batch id of the event in this response body, so it can be ack'd in the next http request
					http_request_time = Time.now - http_start
					
					
					#check if events were returned and process them using the defined @codec
					num_events = 0
					if response.code.to_i == @no_messages_response_code
						#HTTP Response code indicated there are no messages. Skip processing response and sleep.
						batch_id = nil
					elsif response.code.to_i != 200
						@logger.warn("Received non-200 response code: #{response.code}. Will not process this response.")
					elsif response.body.nil?
						@logger.warn("Received normal #{response.code} response code, but the response body is empty. Will not process this response.")
					else #normal HTTP 200 OK response body -- process this response
						codec_start = Time.now
						events = Array.new #will store the decoded & decorated event(s) from the message body in this temporary in-memory array
						@codec.decode(response.body) do |event|
							event[@response_object_name] = {}
							if @include_response_headers 
								event[@response_object_name]["headers"] = response
							end
							if @include_response_code 
								event[@response_object_name]["code"] = response.code.to_i
							end
							if @include_http_request_time 
								event[@response_object_name]["took_secs"] = http_request_time
							end
							decorate(event)
							events.push(event)
						end #end decoding events in response body
						num_events = events.length
						codec_parse_time = Time.now - codec_start
						
						#now queue the events to Logstash's bounded input queue and time how long it takes
						queue_start = Time.now
						events.each{ |event|
							#@logger.info("Queueing event")
							queue << event #blocks if queue is full
							#@logger.info("Event has been queued")
						}
						queue_time = Time.now - queue_start
						@logger.info("HTTP GET request processed #{events.length} events. http_request_secs=#{http_request_time}, codec_parse_secs=#{codec_parse_time}, queueing_secs=#{queue_time}, queue_size=#{queue.length}/#{queue.max}, queue_num_threads_waiting=#{queue.num_waiting}. Server=" + response["Server"] + ". Request=" + @uri.host + @uri.request_uri)
					end #end normal processing of HTTP response body
					
					#TODO: should we provide an option to post back (ack) immetiately once we sucecssfully queue all the messages in the response
					
					if(sleepIval > 0)
						@logger.debug("Waiting #{sleepIval} seconds before next http request")
						sleep(sleepIval)
					end
				end #while loop
			end #HTTP keepalive
		rescue => x
			if x.instance_of?(EOFError)
				#this seems to happen if the http keepalive times out and server disconnects
				@logger.warn("HTTP Connection has closed (EOFError), will reset http client connection and try again.", :exception => x)
				sleep(1)
			else
				@logger.warn("Error occurred, resetting http client connection and trying again in 10 seconds.", :exception => x)
				@logger.warn(x.backtrace)
				sleep(10) #todo: configurable sleep time for errors?
			end
			retry
		end #end begin outside of the loop
		@logger.warn("Unexpected: HTTP client has ended")
	end # def run
end # class LogStash::Inputs::Example