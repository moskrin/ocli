
require 'ripl'
require 'ripl/color_result'
require 'ripl/color_streams'
require 'ripl/rc'

require 'logger'
require 'yaml'

require 'oci8' # database adapter
require 'highline/import'
require 'terminal-table'

class Ocli

  ORACLE_KEYWORDS = %w[
    access  else  modify  start
    add exclusive noaudit select
    all exists  nocompress  session
    alter file  not set
    and float notfound  share
    any for nowait  size
    arraylen  from  null  smallint
    as  grant number  sqlbuf
    asc group of  successful
    audit having  offline synonym
    between identified  on  sysdate
    by  immediate online  table
    char  in  option  then
    check increment or  to
    cluster index order trigger
    column  initial pctfree uid
    comment insert  prior union
    compress  integer privileges  unique
    connect intersect public  update
    create  into  raw user
    current is  rename  validate
    date  level resource  values
    decimal like  revoke  varchar
    default lock  row varchar2
    delete  long  rowid view
    desc  maxextents  rowlabel  whenever
    distinct  minus rownum  where
    drop  mode  rows  with
  ]

  module Shell
    def before_loop
      super
    end

    def loop_eval(expression)
      ret = nil
      expressions = [expression.split(/;/)].flatten.compact
      expressions.each do |expression|
        expression.strip!
        p [:expression,expression]
        case expression.downcase
        when ""
          # do nothing.

        # ::Runtime commands
        when /^(connect|query|use|show_tables)/
          Ripl.config[:rocket_mode] = false
          args = expression.split /\s+/
          Shell.runtime.send(*args)

        # Oracle SQL Commands
        when /^#{ORACLE_KEYWORDS.join("|")}\s+/
          Shell.runtime.ascii_query(expression)

        # Ripl (like irb)
        else
          ret = super
        end
      end
      if ret.nil?
        Ripl.config[:rocket_mode] = false
      else
        Ripl.config[:rocket_mode] = true
      end
      ret
    end

    def self.runtime
      @runtime ||= ::Ocli::Runtime.new
    end
  end

  class Runtime

    def initialize
      @log = Logger.new(STDERR)
      @log.formatter = proc do |severity, datetime, progname, msg|
        "#{severity}: #{msg}\n"
      end
    end

    def log
      @log
    end

    # connection_string
    #   yaml_name [username] [password]
    #   tns_name username [password]
    #   //host:port/service_name username [password]
    #
    #  yaml_name
    #   references the keys from ~/.ocli.yml
    #   ---
    #   my_conn_name:
    #    # dsn
    #    dsn: //hostname:port/service_name
    #    # or long hand
    #    host: hostname
    #    port: 1521
    #    service_name: sn
    #
    #    username: username
    #    password: password  # optional
    def connect(connection_string,*args)
      @config ||= YAML.load_file(File.join(ENV["HOME"] || "~", ".ocli.yml"))
      @tns_names ||= {}

      case connection_string
      when *@config.keys
        # YAML
        config = @config[connection_string]
        if config['dsn']
          @dsn = config['dsn']
        else
          host = config['host'] || 'localhost'
          port = config['port'] || 1521
          service_name = config['service_name']
          @dsn = "//%s:%s/%s" % [ host, port, service_name ]
        end

        @username = config['username'] unless config['username'].nil?
        @password = config['password'] unless config['password'].nil?

      # TNS: tns_name [username] [password]
      when *@tns_names.keys
        log.info "Establishing tns_name connection"
        @dsn = connection_string

      when /^\/\//
        # Oracle: //host:port/service_name [username] [password]
        @dsn = connection_string

      else
        log.error "unknown connection string '#{connection_string}'"
      end

      # args overrides
      username, password = args
      password = nil if @username != username # dependent
      @username = username unless username.nil?
      @password = password unless password.nil?

      # ensure variables
      @dsn ||= ask("dsn: ")
      @username ||= ask("username: ")
      @password ||= ask("password: ") {|q| q.echo = false } # shh

      log.info "Connecting to #{@dsn} as #{@username}"
      begin
        @db = OCI8.new(@username,@password, @dsn)
      rescue OCIError => e
        log.error e
        return
      end

      @result = {
        db: @db,
        time: Time.new
      }
      log.debug @result
      #@db = OCI8.new(username, password, dsn)
    end
    alias :use :connect

    def query(sql, params={})
      log.debug [sql,params]
      cursor = @db.parse(sql)
      sql_params = sql.scan(/:(\w+)/).flatten.uniq
      params.each_pair do |name, value|
        log.debug "bind :#{name} => #{value}"
        cursor.bind_param(":#{name}", value)
      end
      cursor.exec()
      cursor
    end

    def to_arr(cursor)
      rows = []
      while (row = cursor.fetch)
        rows << row
      end
      rows
    end

    def to_txt(cursor)
      columns = []
      hr = []
      cursor.column_metadata.each do |meta|
        columns << meta.name
        hr << meta.name.gsub(/./,'-')
      end

      table = Terminal::Table.new do |t|
        t.add_row columns
        t.add_separator
        while (row = cursor.fetch)
          t.add_row row
        end
      end
      puts table
    end

    def ascii_query(sql,params={})
      p [:ascii_query,sql,params]
      to_txt(query(sql,params))
    end

    def show_tables
      cursor = query("select table_name from user_tables")
      puts to_arr(cursor).flatten.sort
    end
  end


  def self.init
  end

  def echo(str="")
    puts "-- #{str}"
  end

  def help(usage_for=nil)
    case usage_for
    when 'readme'
    else
      puts <<-HELP
> help # for a list of commands
      HELP
    end
  end

  def to_s
    "ocli"
  end

end

Ripl::Shell.send :include, Ocli::Shell
require 'ripl/multi_line'

