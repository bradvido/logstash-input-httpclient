# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "net/http"

# Query a http server at a regular interval to get events
#

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

  public
  def register
    @uri = URI(@url)
  end # def register

  def run(queue)
    Net::HTTP.start @uri.host, @uri.port do |http|
      Stud.interval(@interval) do
        start = Time.now
        resp = http.get @url
        elapsed = Time.now - start
        event = LogStash::Event.new("message" => resp.body, "http_response_code" => resp.code, "http_request_took" => elapsed, "http_response_headers" => resp, "host" => @host)
        decorate(event)
        queue << event
      end #interval loop
    end #HTTP keepalive start
  end # def run

end # class LogStash::Inputs::Example