# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "socket" # for Socket.gethostname
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
    @host = Socket.gethostname
    @uri = URI(@url)
  end # def register

  def run(queue)
    start = Time.now
    Net::HTTP.start @uri.host, @uri.port do |http|
      Stud.interval(@interval) do
        resp = http.get @url
        elapsed = Time.now - start # => 2.5 - doh! keepalive, but no pipelining
        event = LogStash::Event.new("http_response" => resp, "http_request_took" => elapsed, "host" => @host)
        decorate(event)
        queue << event
      end #interval loop
    end #HTTP keepalive start
  end # def run

end # class LogStash::Inputs::Example