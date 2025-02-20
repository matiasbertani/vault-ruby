# Vendored and modified from github.com/drbrain/net-http-persistent
#
require 'net/http'
require 'uri'
require 'cgi' # for escaping
require 'vault/vendor/connection_pool'

begin
  require 'net/http/pipeline'
rescue LoadError
end

autoload :OpenSSL, 'openssl'

##
# Persistent connections for Net::HTTP
#
# PersistentHTTP maintains persistent connections across all the
# servers you wish to talk to.  For each host:port you communicate with a
# single persistent connection is created.
#
# Multiple PersistentHTTP objects will share the same set of
# connections.
#
# For each thread you start a new connection will be created.  A
# PersistentHTTP connection will not be shared across threads.
#
# You can shut down the HTTP connections when done by calling #shutdown.  You
# should name your PersistentHTTP object if you intend to call this
# method.
#
# Example:
#
#   require 'net/http/persistent'
#
#   uri = URI 'http://example.com/awesome/web/service'
#
#   http = PersistentHTTP.new 'my_app_name'
#
#   # perform a GET
#   response = http.request uri
#
#   # or
#
#   get = Net::HTTP::Get.new uri.request_uri
#   response = http.request get
#
#   # create a POST
#   post_uri = uri + 'create'
#   post = Net::HTTP::Post.new post_uri.path
#   post.set_form_data 'some' => 'cool data'
#
#   # perform the POST, the URI is always required
#   response http.request post_uri, post
#
# Note that for GET, HEAD and other requests that do not have a body you want
# to use URI#request_uri not URI#path.  The request_uri contains the query
# params which are sent in the body for other requests.
#
# == SSL
#
# SSL connections are automatically created depending upon the scheme of the
# URI.  SSL connections are automatically verified against the default
# certificate store for your computer.  You can override this by changing
# verify_mode or by specifying an alternate cert_store.
#
# Here are the SSL settings, see the individual methods for documentation:
#
# #certificate        :: This client's certificate
# #ca_file            :: The certificate-authorities
# #ca_path            :: Directory with certificate-authorities
# #cert_store         :: An SSL certificate store
# #ciphers            :: List of SSl ciphers allowed
# #private_key        :: The client's SSL private key
# #reuse_ssl_sessions :: Reuse a previously opened SSL session for a new
#                        connection
# #ssl_timeout        :: SSL session lifetime
# #ssl_version        :: Which specific SSL version to use
# #verify_callback    :: For server certificate verification
# #verify_depth       :: Depth of certificate verification
# #verify_mode        :: How connections should be verified
#
# == Proxies
#
# A proxy can be set through #proxy= or at initialization time by providing a
# second argument to ::new.  The proxy may be the URI of the proxy server or
# <code>:ENV</code> which will consult environment variables.
#
# See #proxy= and #proxy_from_env for details.
#
# == Headers
#
# Headers may be specified for use in every request.  #headers are appended to
# any headers on the request.  #override_headers replace existing headers on
# the request.
#
# The difference between the two can be seen in setting the User-Agent.  Using
# <code>http.headers['User-Agent'] = 'MyUserAgent'</code> will send "Ruby,
# MyUserAgent" while <code>http.override_headers['User-Agent'] =
# 'MyUserAgent'</code> will send "MyUserAgent".
#
# == Tuning
#
# === Segregation
#
# By providing an application name to ::new you can separate your connections
# from the connections of other applications.
#
# === Idle Timeout
#
# If a connection hasn't been used for this number of seconds it will automatically be
# reset upon the next use to avoid attempting to send to a closed connection.
# The default value is 5 seconds. nil means no timeout. Set through #idle_timeout.
#
# Reducing this value may help avoid the "too many connection resets" error
# when sending non-idempotent requests while increasing this value will cause
# fewer round-trips.
#
# === Read Timeout
#
# The amount of time allowed between reading two chunks from the socket.  Set
# through #read_timeout
#
# === Max Requests
#
# The number of requests that should be made before opening a new connection.
# Typically many keep-alive capable servers tune this to 100 or less, so the
# 101st request will fail with ECONNRESET. If unset (default), this value has no
# effect, if set, connections will be reset on the request after max_requests.
#
# === Open Timeout
#
# The amount of time to wait for a connection to be opened.  Set through
# #open_timeout.
#
# === Socket Options
#
# Socket options may be set on newly-created connections.  See #socket_options
# for details.
#
# === Non-Idempotent Requests
#
# By default non-idempotent requests will not be retried per RFC 2616.  By
# setting retry_change_requests to true requests will automatically be retried
# once.
#
# Only do this when you know that retrying a POST or other non-idempotent
# request is safe for your application and will not create duplicate
# resources.
#
# The recommended way to handle non-idempotent requests is the following:
#
#   require 'net/http/persistent'
#
#   uri = URI 'http://example.com/awesome/web/service'
#   post_uri = uri + 'create'
#
#   http = PersistentHTTP.new 'my_app_name'
#
#   post = Net::HTTP::Post.new post_uri.path
#   # ... fill in POST request
#
#   begin
#     response = http.request post_uri, post
#   rescue PersistentHTTP::Error
#
#     # POST failed, make a new request to verify the server did not process
#     # the request
#     exists_uri = uri + '...'
#     response = http.get exists_uri
#
#     # Retry if it failed
#     retry if response.code == '404'
#   end
#
# The method of determining if the resource was created or not is unique to
# the particular service you are using.  Of course, you will want to add
# protection from infinite looping.
#
# === Connection Termination
#
# If you are done using the PersistentHTTP instance you may shut down
# all the connections in the current thread with #shutdown.  This is not
# recommended for normal use, it should only be used when it will be several
# minutes before you make another HTTP request.
#
# If you are using multiple threads, call #shutdown in each thread when the
# thread is done making requests.  If you don't call shutdown, that's OK.
# Ruby will automatically garbage collect and shutdown your HTTP connections
# when the thread terminates.

module Vault
class PersistentHTTP

  ##
  # The beginning of Time

  EPOCH = Time.at 0 # :nodoc:

  ##
  # Is OpenSSL available?  This test works with autoload

  HAVE_OPENSSL = defined? OpenSSL::SSL # :nodoc:

  ##
  # The version of PersistentHTTP you are using

  VERSION = '3.0.0'

  ##
  # Exceptions rescued for automatic retry on ruby 2.0.0.  This overlaps with
  # the exception list for ruby 1.x.

  RETRIED_EXCEPTIONS = [ # :nodoc:
    (Net::ReadTimeout if Net.const_defined? :ReadTimeout),
    IOError,
    EOFError,
    Errno::ECONNRESET,
    Errno::ECONNABORTED,
    Errno::EPIPE,
    (OpenSSL::SSL::SSLError if HAVE_OPENSSL),
    Timeout::Error,
  ].compact

  ##
  # Error class for errors raised by PersistentHTTP.  Various
  # SystemCallErrors are re-raised with a human-readable message under this
  # class.

  class Error < StandardError; end

  ##
  # Use this method to detect the idle timeout of the host at +uri+.  The
  # value returned can be used to configure #idle_timeout.  +max+ controls the
  # maximum idle timeout to detect.
  #
  # After
  #
  # Idle timeout detection is performed by creating a connection then
  # performing a HEAD request in a loop until the connection terminates
  # waiting one additional second per loop.
  #
  # NOTE:  This may not work on ruby > 1.9.

  def self.detect_idle_timeout uri, max = 10
    uri = URI uri unless URI::Generic === uri
    uri += '/'

    req = Net::HTTP::Head.new uri.request_uri

    http = new 'net-http-persistent detect_idle_timeout'

    http.connection_for uri do |connection|
      sleep_time = 0

      http = connection.http

      loop do
        response = http.request req

        $stderr.puts "HEAD #{uri} => #{response.code}" if $DEBUG

        unless Net::HTTPOK === response then
          raise Error, "bad response code #{response.code} detecting idle timeout"
        end

        break if sleep_time >= max

        sleep_time += 1

        $stderr.puts "sleeping #{sleep_time}" if $DEBUG
        sleep sleep_time
      end
    end
  rescue
    # ignore StandardErrors, we've probably found the idle timeout.
  ensure
    return sleep_time unless $!
  end

  ##
  # This client's OpenSSL::X509::Certificate

  attr_reader :certificate

  ##
  # For Net::HTTP parity

  alias cert certificate

  ##
  # An SSL certificate authority.  Setting this will set verify_mode to
  # VERIFY_PEER.

  attr_reader :ca_file

  ##
  # A directory of SSL certificates to be used as certificate authorities.
  # Setting this will set verify_mode to VERIFY_PEER.

  attr_reader :ca_path

  ##
  # An SSL certificate store.  Setting this will override the default
  # certificate store.  See verify_mode for more information.

  attr_reader :cert_store

  ##
  # The ciphers allowed for SSL connections

  attr_reader :ciphers

  ##
  # Sends debug_output to this IO via Net::HTTP#set_debug_output.
  #
  # Never use this method in production code, it causes a serious security
  # hole.

  attr_accessor :debug_output

  ##
  # Current connection generation

  attr_reader :generation # :nodoc:

  ##
  # Headers that are added to every request using Net::HTTP#add_field

  attr_reader :headers

  ##
  # Maps host:port to an HTTP version.  This allows us to enable version
  # specific features.

  attr_reader :http_versions

  ##
  # Maximum time an unused connection can remain idle before being
  # automatically closed.

  attr_accessor :idle_timeout

  ##
  # Maximum number of requests on a connection before it is considered expired
  # and automatically closed.

  attr_accessor :max_requests

  ##
  # The value sent in the Keep-Alive header.  Defaults to 30.  Not needed for
  # HTTP/1.1 servers.
  #
  # This may not work correctly for HTTP/1.0 servers
  #
  # This method may be removed in a future version as RFC 2616 does not
  # require this header.

  attr_accessor :keep_alive

  ##
  # A name for this connection.  Allows you to keep your connections apart
  # from everybody else's.

  attr_reader :name

  ##
  # Seconds to wait until a connection is opened.  See Net::HTTP#open_timeout

  attr_accessor :open_timeout

  ##
  # Headers that are added to every request using Net::HTTP#[]=

  attr_reader :override_headers

  ##
  # This client's SSL private key

  attr_reader :private_key

  ##
  # For Net::HTTP parity

  alias key private_key

  ##
  # The URL through which requests will be proxied

  attr_reader :proxy_uri

  ##
  # List of host suffixes which will not be proxied

  attr_reader :no_proxy

  ##
  # Test-only accessor for the connection pool

  attr_reader :pool # :nodoc:

  ##
  # Seconds to wait until reading one block.  See Net::HTTP#read_timeout

  attr_accessor :read_timeout

  ##
  # By default SSL sessions are reused to avoid extra SSL handshakes.  Set
  # this to false if you have problems communicating with an HTTPS server
  # like:
  #
  #   SSL_connect [...] read finished A: unexpected message (OpenSSL::SSL::SSLError)

  attr_accessor :reuse_ssl_sessions

  ##
  # An array of options for Socket#setsockopt.
  #
  # By default the TCP_NODELAY option is set on sockets.
  #
  # To set additional options append them to this array:
  #
  #   http.socket_options << [Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, 1]

  attr_reader :socket_options

  ##
  # Current SSL connection generation

  attr_reader :ssl_generation # :nodoc:

  ##
  # SSL session lifetime

  attr_reader :ssl_timeout

  ##
  # SSL version to use.
  #
  # By default, the version will be negotiated automatically between client
  # and server.  Ruby 1.9 and newer only.

  attr_reader :ssl_version

  ##
  # Where this instance's last-use times live in the thread local variables

  attr_reader :timeout_key # :nodoc:

  ##
  # SSL verification callback.  Used when ca_file or ca_path is set.

  attr_reader :verify_callback

  ##
  # Sets the depth of SSL certificate verification

  attr_reader :verify_depth

  ##
  # HTTPS verify mode.  Defaults to OpenSSL::SSL::VERIFY_PEER which verifies
  # the server certificate.
  #
  # If no ca_file, ca_path or cert_store is set the default system certificate
  # store is used.
  #
  # You can use +verify_mode+ to override any default values.

  attr_reader :verify_mode

  ##
  # Enable retries of non-idempotent requests that change data (e.g. POST
  # requests) when the server has disconnected.
  #
  # This will in the worst case lead to multiple requests with the same data,
  # but it may be useful for some applications.  Take care when enabling
  # this option to ensure it is safe to POST or perform other non-idempotent
  # requests to the server.

  attr_accessor :retry_change_requests

  ##
  # Creates a new PersistentHTTP.
  #
  # Set +name+ to keep your connections apart from everybody else's.  Not
  # required currently, but highly recommended.  Your library name should be
  # good enough.  This parameter will be required in a future version.
  #
  # +proxy+ may be set to a URI::HTTP or :ENV to pick up proxy options from
  # the environment.  See proxy_from_env for details.
  #
  # In order to use a URI for the proxy you may need to do some extra work
  # beyond URI parsing if the proxy requires a password:
  #
  #   proxy = URI 'http://proxy.example'
  #   proxy.user     = 'AzureDiamond'
  #   proxy.password = 'hunter2'
  #
  # Set +pool_size+ to limit the maximum number of connections allowed.
  # Defaults to 1/4 the number of allowed file handles.  You can have no more
  # than this many threads with active HTTP transactions.

  def initialize name=nil, proxy=nil, pool_size=Vault::Defaults::DEFAULT_POOL_SIZE, pool_timeout=Vault::Defaults::DEFAULT_POOL_TIMEOUT
    @name = name

    @debug_output     = nil
    @proxy_uri        = nil
    @no_proxy         = []
    @headers          = {}
    @override_headers = {}
    @http_versions    = {}
    @keep_alive       = 30
    @open_timeout     = nil
    @read_timeout     = nil
    @idle_timeout     = 5
    @max_requests     = nil
    @socket_options   = []
    @ssl_generation   = 0 # incremented when SSL session variables change

    @socket_options << [Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1] if
      Socket.const_defined? :TCP_NODELAY

    @pool = PersistentHTTP::Pool.new size: pool_size, timeout: pool_timeout do |http_args|
      PersistentHTTP::Connection.new Net::HTTP, http_args, @ssl_generation
    end

    @certificate        = nil
    @ca_file            = nil
    @ca_path            = nil
    @ciphers            = nil
    @private_key        = nil
    @ssl_timeout        = nil
    @ssl_version        = nil
    @verify_callback    = nil
    @verify_depth       = nil
    @verify_mode        = nil
    @cert_store         = nil

    @generation         = 0 # incremented when proxy URI changes

    if HAVE_OPENSSL then
      @verify_mode        = OpenSSL::SSL::VERIFY_PEER
      @reuse_ssl_sessions = OpenSSL::SSL.const_defined? :Session
    end

    @retry_change_requests = false

    self.proxy = proxy if proxy
  end

  ##
  # Sets this client's OpenSSL::X509::Certificate

  def certificate= certificate
    @certificate = certificate

    reconnect_ssl
  end

  # For Net::HTTP parity
  alias cert= certificate=

  ##
  # Sets the SSL certificate authority file.

  def ca_file= file
    @ca_file = file

    reconnect_ssl
  end

  ##
  # Sets the SSL certificate authority path.

  def ca_path= path
    @ca_path = path

    reconnect_ssl
  end

  ##
  # Overrides the default SSL certificate store used for verifying
  # connections.

  def cert_store= store
    @cert_store = store

    reconnect_ssl
  end

  ##
  # The ciphers allowed for SSL connections

  def ciphers= ciphers
    @ciphers = ciphers

    reconnect_ssl
  end

  ##
  # Creates a new connection for +uri+

  def connection_for uri
    use_ssl = uri.scheme.downcase == 'https'

    net_http_args = [uri.hostname, uri.port]

    net_http_args.concat @proxy_args if
      @proxy_uri and not proxy_bypass? uri.hostname, uri.port

    connection = @pool.checkout net_http_args

    http = connection.http

    connection.ressl @ssl_generation if
      connection.ssl_generation != @ssl_generation

    if not http.started? then
      ssl   http if use_ssl
      start http
    elsif expired? connection then
      reset connection
    end

    http.read_timeout = @read_timeout if @read_timeout
    http.keep_alive_timeout = @idle_timeout if @idle_timeout

    return yield connection
  rescue Errno::ECONNREFUSED
    address = http.proxy_address || http.address
    port    = http.proxy_port    || http.port

    raise Error, "connection refused: #{address}:#{port}"
  rescue Errno::EHOSTDOWN
    address = http.proxy_address || http.address
    port    = http.proxy_port    || http.port

    raise Error, "host down: #{address}:#{port}"
  ensure
    # Only perform checkin if we successfully checked a connection out
    if connection
      @pool.checkin net_http_args
    end
  end

  ##
  # Returns an error message containing the number of requests performed on
  # this connection

  def error_message connection
    connection.requests -= 1 # fixup

    age = Time.now - connection.last_use

    "after #{connection.requests} requests on #{connection.http.object_id}, " \
      "last used #{age} seconds ago"
  end

  ##
  # URI::escape wrapper

  def escape str
    CGI.escape str if str
  end

  ##
  # URI::unescape wrapper

  def unescape str
    CGI.unescape str if str
  end


  ##
  # Returns true if the connection should be reset due to an idle timeout, or
  # maximum request count, false otherwise.

  def expired? connection
    return true  if     @max_requests && connection.requests >= @max_requests
    return false unless @idle_timeout
    return true  if     @idle_timeout.zero?

    Time.now - connection.last_use > @idle_timeout
  end

  ##
  # Starts the Net::HTTP +connection+

  def start http
    http.set_debug_output @debug_output if @debug_output
    http.open_timeout = @open_timeout if @open_timeout

    http.start

    socket = http.instance_variable_get :@socket

    if socket then # for fakeweb
      @socket_options.each do |option|
        socket.io.setsockopt(*option)
      end
    end
  end

  ##
  # Finishes the Net::HTTP +connection+

  def finish connection
    connection.finish

    connection.http.instance_variable_set :@ssl_session, nil unless
      @reuse_ssl_sessions
  end

  ##
  # Returns the HTTP protocol version for +uri+

  def http_version uri
    @http_versions["#{uri.hostname}:#{uri.port}"]
  end

  ##
  # Is +req+ idempotent according to RFC 2616?

  def idempotent? req
    case req
    when Net::HTTP::Delete, Net::HTTP::Get, Net::HTTP::Head,
         Net::HTTP::Options, Net::HTTP::Put, Net::HTTP::Trace then
      true
    end
  end

  ##
  # Is the request +req+ idempotent or is retry_change_requests allowed.

  def can_retry? req
    @retry_change_requests && !idempotent?(req)
  end

  ##
  # Adds "http://" to the String +uri+ if it is missing.

  def normalize_uri uri
    (uri =~ /^https?:/) ? uri : "http://#{uri}"
  end

  ##
  # Pipelines +requests+ to the HTTP server at +uri+ yielding responses if a
  # block is given.  Returns all responses recieved.
  #
  # See
  # Net::HTTP::Pipeline[http://docs.seattlerb.org/net-http-pipeline/Net/HTTP/Pipeline.html]
  # for further details.
  #
  # Only if <tt>net-http-pipeline</tt> was required before
  # <tt>net-http-persistent</tt> #pipeline will be present.

  def pipeline uri, requests, &block # :yields: responses
    connection_for uri do |connection|
      connection.http.pipeline requests, &block
    end
  end

  ##
  # Sets this client's SSL private key

  def private_key= key
    @private_key = key

    reconnect_ssl
  end

  # For Net::HTTP parity
  alias key= private_key=

  ##
  # Sets the proxy server.  The +proxy+ may be the URI of the proxy server,
  # the symbol +:ENV+ which will read the proxy from the environment or nil to
  # disable use of a proxy.  See #proxy_from_env for details on setting the
  # proxy from the environment.
  #
  # If the proxy URI is set after requests have been made, the next request
  # will shut-down and re-open all connections.
  #
  # The +no_proxy+ query parameter can be used to specify hosts which shouldn't
  # be reached via proxy; if set it should be a comma separated list of
  # hostname suffixes, optionally with +:port+ appended, for example
  # <tt>example.com,some.host:8080</tt>.

  def proxy= proxy
    @proxy_uri = case proxy
                 when :ENV      then proxy_from_env
                 when URI::HTTP then proxy
                 when nil       then # ignore
                 else raise ArgumentError, 'proxy must be :ENV or a URI::HTTP'
                 end

    @no_proxy.clear

    if @proxy_uri then
      @proxy_args = [
        @proxy_uri.hostname,
        @proxy_uri.port,
        unescape(@proxy_uri.user),
        unescape(@proxy_uri.password),
      ]

      @proxy_connection_id = [nil, *@proxy_args].join ':'

      if @proxy_uri.query then
        @no_proxy = CGI.parse(@proxy_uri.query)['no_proxy'].join(',').downcase.split(',').map { |x| x.strip }.reject { |x| x.empty? }
      end
    end

    reconnect
    reconnect_ssl
  end

  ##
  # Creates a URI for an HTTP proxy server from ENV variables.
  #
  # If +HTTP_PROXY+ is set a proxy will be returned.
  #
  # If +HTTP_PROXY_USER+ or +HTTP_PROXY_PASS+ are set the URI is given the
  # indicated user and password unless HTTP_PROXY contains either of these in
  # the URI.
  #
  # The +NO_PROXY+ ENV variable can be used to specify hosts which shouldn't
  # be reached via proxy; if set it should be a comma separated list of
  # hostname suffixes, optionally with +:port+ appended, for example
  # <tt>example.com,some.host:8080</tt>. When set to <tt>*</tt> no proxy will
  # be returned.
  #
  # For Windows users, lowercase ENV variables are preferred over uppercase ENV
  # variables.

  def proxy_from_env
    env_proxy = ENV['http_proxy'] || ENV['HTTP_PROXY']

    return nil if env_proxy.nil? or env_proxy.empty?

    uri = URI normalize_uri env_proxy

    env_no_proxy = ENV['no_proxy'] || ENV['NO_PROXY']

    # '*' is special case for always bypass
    return nil if env_no_proxy == '*'

    if env_no_proxy then
      uri.query = "no_proxy=#{escape(env_no_proxy)}"
    end

    unless uri.user or uri.password then
      uri.user     = escape ENV['http_proxy_user'] || ENV['HTTP_PROXY_USER']
      uri.password = escape ENV['http_proxy_pass'] || ENV['HTTP_PROXY_PASS']
    end

    uri
  end

  ##
  # Returns true when proxy should by bypassed for host.

  def proxy_bypass? host, port
    host = host.downcase
    host_port = [host, port].join ':'

    @no_proxy.each do |name|
      return true if host[-name.length, name.length] == name or
         host_port[-name.length, name.length] == name
    end

    false
  end

  ##
  # Forces reconnection of HTTP connections.

  def reconnect
    @generation += 1
  end

  ##
  # Forces reconnection of SSL connections.

  def reconnect_ssl
    @ssl_generation += 1
  end

  ##
  # Finishes then restarts the Net::HTTP +connection+

  def reset connection
    http = connection.http

    finish connection

    start http
  rescue Errno::ECONNREFUSED
    e = Error.new "connection refused: #{http.address}:#{http.port}"
    e.set_backtrace $@
    raise e
  rescue Errno::EHOSTDOWN
    e = Error.new "host down: #{http.address}:#{http.port}"
    e.set_backtrace $@
    raise e
  end

  ##
  # Makes a request on +uri+.  If +req+ is nil a Net::HTTP::Get is performed
  # against +uri+.
  #
  # If a block is passed #request behaves like Net::HTTP#request (the body of
  # the response will not have been read).
  #
  # +req+ must be a Net::HTTPRequest subclass (see Net::HTTP for a list).
  #
  # If there is an error and the request is idempotent according to RFC 2616
  # it will be retried automatically.

  def request uri, req = nil, &block
    retried      = false
    bad_response = false

    uri      = URI uri
    req      = request_setup req || uri
    response = nil

    connection_for uri do |connection|
      http = connection.http

      begin
        connection.requests += 1

        response = http.request req, &block

        if req.connection_close? or
           (response.http_version <= '1.0' and
            not response.connection_keep_alive?) or
           response.connection_close? then
          finish connection
        end
      rescue Net::HTTPBadResponse => e
        message = error_message connection

        finish connection

        raise Error, "too many bad responses #{message}" if
        bad_response or not can_retry? req

        bad_response = true
        retry
      rescue *RETRIED_EXCEPTIONS => e
        request_failed e, req, connection if
          retried or not can_retry? req

        reset connection

        retried = true
        retry
      rescue Errno::EINVAL, Errno::ETIMEDOUT => e # not retried on ruby 2
        request_failed e, req, connection if retried or not can_retry? req

        reset connection

        retried = true
        retry
      rescue Exception => e
        finish connection

        raise
      ensure
        connection.last_use = Time.now
      end
    end

    @http_versions["#{uri.hostname}:#{uri.port}"] ||= response.http_version

    response
  end

  ##
  # Raises an Error for +exception+ which resulted from attempting the request
  # +req+ on the +connection+.
  #
  # Finishes the +connection+.

  def request_failed exception, req, connection # :nodoc:
    due_to = "(due to #{exception.message} - #{exception.class})"
    message = "too many connection resets #{due_to} #{error_message connection}"

    finish connection

    raise Error, message, exception.backtrace
  end

  ##
  # Creates a GET request if +req_or_uri+ is a URI and adds headers to the
  # request.
  #
  # Returns the request.

  def request_setup req_or_uri # :nodoc:
    req = if URI === req_or_uri then
            Net::HTTP::Get.new req_or_uri.request_uri
          else
            req_or_uri
          end

    @headers.each do |pair|
      req.add_field(*pair)
    end

    @override_headers.each do |name, value|
      req[name] = value
    end

    unless req['Connection'] then
      req.add_field 'Connection', 'keep-alive'
      req.add_field 'Keep-Alive', @keep_alive
    end

    req
  end

  ##
  # Shuts down all connections
  #
  # *NOTE*: Calling shutdown for can be dangerous!
  #
  # If any thread is still using a connection it may cause an error!  Call
  # #shutdown when you are completely done making requests!

  def shutdown
    @pool.available.shutdown do |http|
      http.finish
    end
  end

  ##
  # Enables SSL on +connection+

  def ssl connection
    connection.use_ssl = true

    connection.ciphers     = @ciphers     if @ciphers
    connection.ssl_timeout = @ssl_timeout if @ssl_timeout
    connection.ssl_version = @ssl_version if @ssl_version

    connection.verify_depth = @verify_depth
    connection.verify_mode  = @verify_mode

    if OpenSSL::SSL::VERIFY_PEER == OpenSSL::SSL::VERIFY_NONE and
       not Object.const_defined?(:I_KNOW_THAT_OPENSSL_VERIFY_PEER_EQUALS_VERIFY_NONE_IS_WRONG) then
      warn <<-WARNING
                             !!!SECURITY WARNING!!!

The SSL HTTP connection to:

  #{connection.address}:#{connection.port}

                           !!!MAY NOT BE VERIFIED!!!

On your platform your OpenSSL implementation is broken.

There is no difference between the values of VERIFY_NONE and VERIFY_PEER.

This means that attempting to verify the security of SSL connections may not
work.  This exposes you to man-in-the-middle exploits, snooping on the
contents of your connection and other dangers to the security of your data.

To disable this warning define the following constant at top-level in your
application:

  I_KNOW_THAT_OPENSSL_VERIFY_PEER_EQUALS_VERIFY_NONE_IS_WRONG = nil

      WARNING
    end

    connection.ca_file = @ca_file if @ca_file
    connection.ca_path = @ca_path if @ca_path

    if @ca_file or @ca_path then
      connection.verify_callback = @verify_callback if @verify_callback
    end

    if @certificate and @private_key then
      connection.cert = @certificate
      connection.key  = @private_key
    end

    connection.cert_store = if @cert_store then
                              @cert_store
                            else
                              store = OpenSSL::X509::Store.new
                              store.set_default_paths
                              store
                            end
  end

  ##
  # SSL session lifetime

  def ssl_timeout= ssl_timeout
    @ssl_timeout = ssl_timeout

    reconnect_ssl
  end

  ##
  # SSL version to use

  def ssl_version= ssl_version
    @ssl_version = ssl_version

    reconnect_ssl
  end

  ##
  # Sets the depth of SSL certificate verification

  def verify_depth= verify_depth
    @verify_depth = verify_depth

    reconnect_ssl
  end

  ##
  # Sets the HTTPS verify mode.  Defaults to OpenSSL::SSL::VERIFY_PEER.
  #
  # Setting this to VERIFY_NONE is a VERY BAD IDEA and should NEVER be used.
  # Securely transfer the correct certificate and update the default
  # certificate store or set the ca file instead.

  def verify_mode= verify_mode
    @verify_mode = verify_mode

    reconnect_ssl
  end

  ##
  # SSL verification callback.

  def verify_callback= callback
    @verify_callback = callback

    reconnect_ssl
  end

end
end

require_relative 'persistent/connection'
require_relative 'persistent/pool'
