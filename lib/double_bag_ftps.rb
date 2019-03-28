require 'net/ftp'
require 'rubygems'
begin
  require 'openssl'
rescue LoadError
end

class DoubleBagFTPS < Net::FTP
  EXPLICIT = :explicit
  IMPLICIT = :implicit
  IMPLICIT_PORT = 990

  # The form of FTPS that should be used. Either EXPLICIT or IMPLICIT.
  # Defaults to EXPLICIT.
  attr_reader :ftps_mode

  # The OpenSSL::SSL::SSLContext to use for creating all OpenSSL::SSL::SSLSocket objects.
  attr_accessor :ssl_context_doublebag

  def initialize(host = nil, user = nil, passwd = nil, acct = nil, ftps_mode = EXPLICIT, ssl_context_params = {})
    raise ArgumentError unless valid_ftps_mode?(ftps_mode)

    @ftps_mode = ftps_mode
    @ssl_context_doublebag = DoubleBagFTPS.create_ssl_context(ssl_context_params)
    super(host, user, passwd, acct)
  end

  def self.open(host, user = nil, passwd = nil, acct = nil, ftps_mode = EXPLICIT, ssl_context_params = {})
    if block_given?
      ftps = new(host, user, passwd, acct, ftps_mode, ssl_context_params)
      begin
        yield ftps
      ensure
        ftps.close unless ftps.closed?
      end
    else
      new(host, user, passwd, acct, ftps_mode, ssl_context_params)
    end
  end

  #
  # Allow @ftps_mode to be set when @sock is not connected
  #
  def ftps_mode=(ftps_mode)
    # Ruby 1.8.7/1.9.2 compatible check
    if (defined?(NullSocket) && @sock.is_a?(NullSocket)) || @sock.nil? || @sock.closed?
      raise ArgumentError unless valid_ftps_mode?(ftps_mode)

      @ftps_mode = ftps_mode
    else
      raise 'Cannot set ftps_mode while connected'
    end
  end

  #
  # Establishes the command channel.
  # Override parent to record host name for verification, and allow default implicit port.
  #
  def connect(host, port = ftps_implicit? ? IMPLICIT_PORT : FTP_PORT)
    @hostname = host
    @sock = BufferedSocket.new(@bare_sock, read_timeout: @read_timeout)
    super
  end

  def login(user = 'anonymous', passwd = nil, acct = nil, auth = 'TLS')
    if ftps_explicit?
      synchronize do
        sendcmd('AUTH ' + auth) # Set the security mechanism
        @sock = ssl_socket(@sock)
      end
    end

    super(user, passwd, acct)
    voidcmd('PBSZ 0') # The expected value for Protection Buffer Size (PBSZ) is 0 for TLS/SSL
    voidcmd('PROT P') # Set data channel protection level to Private
  end

  #
  # Override parent to allow an OpenSSL::SSL::SSLSocket to be returned
  # when using implicit FTPS
  #
  def open_socket(host, port, defer_implicit_ssl = false)
    if defined? SOCKSSocket && ENV['SOCKS_SERVER']
      @passive = true
      # sock = SOCKSSocket.open(host, port) commented because doesn't work in ruby 2.4
    else
      sock = TCPSocket.open(host, port)
    end
    !defer_implicit_ssl && ftps_implicit? ? ssl_socket(sock) : sock
  end
  private :open_socket

  #
  # Override parent to support ssl sockets
  #
  def transfercmd(cmd, rest_offset = nil)
    if @passive
      host, port = makepasv

      if @resume && rest_offset
        resp = sendcmd('REST ' + rest_offset.to_s)
        raise FTPReplyError, resp if resp[0] != '3'
      end
      conn = open_socket(host, port, true)
      resp = sendcmd(cmd)
      # skip 2XX for some ftp servers
      resp = getresp if resp[0] == '2'
      raise FTPReplyError, resp if resp[0] != '1'

      conn = ssl_socket(conn) # SSL connection now possible after cmd sent
    else
      sock = makeport
      sendport(sock.addr[3], sock.addr[1]) if sendport_needed?
      if @resume && rest_offset
        resp = sendcmd('REST ' + rest_offset.to_s)
        raise FTPReplyError, resp if resp[0] != '3'
      end
      resp = sendcmd(cmd)
      # skip 2XX for some ftp servers
      resp = getresp if resp[0] == '2'
      raise FTPReplyError, resp if resp[0] != '1'

      conn = sock.accept
      conn = ssl_socket(conn)
      sock.close
    end
    conn
  end
  private :transfercmd

  # Before ruby-2.2.3, makeport called sendport automatically.  After
  # Ruby 2.3.0, makeport does not call sendport automatically, so do
  # it ourselves.  This change to Ruby's FTP lib has been backported
  # to Ruby 2.1 since version 2.1.7.
  def sendport_needed?
    @sendport_needed ||= begin
      Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.2.3') ||
        Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.1.7') &&
          Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.2.0')
    end
  end
  private :sendport_needed?

  def ftps_explicit?
    @ftps_mode == EXPLICIT
  end

  def ftps_implicit?
    @ftps_mode == IMPLICIT
  end

  def valid_ftps_mode?(mode)
    mode == EXPLICIT || mode == IMPLICIT
  end
  private :valid_ftps_mode?

  #
  # Returns a connected OpenSSL::SSL::SSLSocket
  #
  def ssl_socket(sock)
    raise 'SSL extension not installed' unless defined?(OpenSSL)

    sock = OpenSSL::SSL::SSLSocket.new(sock, @ssl_context_doublebag)
    sock.session = @ssl_session if @ssl_session
    sock.sync_close = true
    sock.connect
    print "get: #{sock.peer_cert.to_text}" if @debug_mode
    unless @ssl_context_doublebag.verify_mode == OpenSSL::SSL::VERIFY_NONE
      sock.post_connection_check(@hostname)
    end
    @ssl_session = sock.session
    decorate_socket sock
    sock
  end
  private :ssl_socket

  # Ruby 2.0's Ftp class closes sockets by first doing a shutdown,
  # setting the read timeout, and doing a read.  OpenSSL doesn't
  # have those methods, so fake it.
  #
  # Ftp calls #close in an ensure block, so the socket will still get
  # closed.

  def decorate_socket(sock)
    def sock.shutdown(_how)
      @shutdown = true
    end

    def sock.read_timeout=(seconds); end

    def sock.remote_address
      io.remote_address
    end

    # Skip read after shutdown.  Prevents 2.0 from hanging in
    # Ftp#close

    def sock.read(*args)
      return if @shutdown

      super(*args)
    end
  end
  private :decorate_socket

  def self.create_ssl_context(params = {})
    raise 'SSL extension not installed' unless defined?(OpenSSL)

    context = OpenSSL::SSL::SSLContext.new
    context.set_params(params)
    context
  end
end
