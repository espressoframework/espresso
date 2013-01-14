class EApp

  # Rack interface to all found controllers
  #
  # @example config.ru
  #    module App
  #      class Forum < E
  #        map '/forum'
  #
  #        # ...
  #      end
  #
  #      class Blog < E
  #        map '/blog'
  #
  #        # ...
  #      end
  #    end
  #
  #    run EApp
  def self.call env
    new(:automount).call(env)
  end

  def initialize automount = false, &proc
    @routes = {}
    @controllers = automount ? discover_controllers : []
    @mounted_controllers = []
    @controllers.each {|c| mount_controller c}
    proc && self.instance_exec(&proc)
  end

  # mount given/discovered controllers into current app.
  # any number of arguments accepted.
  # String arguments are treated as roots/canonicals.
  # any other arguments are used to discover controllers.
  # controllers can be passed directly
  # or as a Module that contain controllers
  # or as a Regexp matching controller's name.
  # 
  # proc given here will be executed inside given/discovered controllers.
  #
  def mount *args, &setup
    controllers, roots = [], []
    args.flatten.each do |a|
      if a.is_a?(String)
        roots << rootify_url(a)
      elsif is_app?(a)
        controllers << a
      else
        controllers.concat extract_controllers(a)
      end
    end
    controllers.each {|c| mount_controller c, *roots, &setup}
    self
  end

  # proc given here will be executed inside ALL CONTROLLERS!
  # used to setup multiple controllers at once.
  #
  # @note this method should be called before mounting controllers
  #
  # @example
  #   #class News < E
  #     # ...
  #   end
  #   class Articles < E
  #     # ...
  #   end
  #
  #   # this will work correctly
  #   app = EApp.new
  #   app.global_setup { controllers setup }
  #   app.mount News
  #   app.mount Articles
  #   app.run
  #
  #   # and this will NOT!
  #   app = EApp.new
  #   app.mount News
  #   app.mount Articles
  #   app.global_setup { controllers setup }
  #   app.run
  #
  def global_setup &proc
    @global_setup = proc
    self
  end
  alias setup_controllers global_setup
  alias setup global_setup

  # displays URLs the app will respond to,
  # with controller and action that serving each URL.
  def url_map opts = {}
    map = {}
    sorted_routes.each do |r|
      @routes[r].each_pair { |rm, as| (map[r] ||= {})[rm] = as.dup }
    end

    def map.to_s
      out = []
      self.each_pair do |route, request_methods|
        next if route.source.size == 0
        out << "%s\n" % route.source
        request_methods.each_pair do |request_method, route_setup|
          out << "  %s%s" % [request_method, ' ' * (10 - request_method.size)]
          out << "%s#%s\n" % [route_setup[:ctrl], route_setup[:action]]
        end
        out << "\n"
      end
      out.join
    end
    map
  end
  alias urlmap url_map

  # by default, Espresso will use WEBrick server.
  # pass :server option and any option accepted by selected(or default) server:
  #
  # @example use Thin server with its default port
  #   app.run :server => :Thin
  # @example use EventedMongrel server with custom options
  #   app.run :server => :EventedMongrel, :port => 9090, :num_processors => 1000
  #
  # @param [Hash] opts
  # @option opts [Symbol]  :server (:WEBrick) web server
  # @option opts [Integer] :port   (5252)
  # @option opts [String]  :host   (0.0.0.0)
  def run opts = {}
    server = opts.delete(:server)
    (server && Rack::Handler.const_defined?(server)) || (server = HTTP__DEFAULT_SERVER)

    port = opts.delete(:port)
    opts[:Port] ||= port || HTTP__DEFAULT_PORT

    host = opts.delete(:host) || opts.delete(:bind)
    opts[:Host] = host if host

    Rack::Handler.const_get(server).run app, opts
  end

  def call env
    app.call env
  end

  private
  def app
    @app ||= middleware.reverse.inject(lambda {|env| call!(env)}) {|a,e| e[a]}
  end

  def call! env
    path = env[ENV__PATH_INFO]
    script_name = env[ENV__SCRIPT_NAME]

    sorted_routes.each do |route|
      if matches = route.match(path)

        if route_setup = @routes[route][env[ENV__REQUEST_METHOD]]

          if route_setup[:rewriter]
            app = EspressoFrameworkRewriter.new(*matches.captures, &route_setup[:rewriter])
            return app.call(env)
          elsif route_setup[:app]
            env[ENV__PATH_INFO] = matches[1].to_s
            return route_setup[:app].call(env)
          else
            path_info = matches[1].to_s

            env[ENV__SCRIPT_NAME] = (route_setup[:path]).freeze
            env[ENV__PATH_INFO]   = (path_ok?(path_info) ? path_info : '/' << path_info).freeze

            epi, format = nil
            (fr = route_setup[:format_regexp]) && (epi, format = path_info.split(fr))
            env[ENV__ESPRESSO_PATH_INFO] = epi
            env[ENV__ESPRESSO_FORMAT]    = format

            app = Rack::Builder.new
            app.run route_setup[:ctrl].new(route_setup[:action])
            route_setup[:ctrl].middleware.each {|w,a,p| app.use w, *a, &p}
            return app.call(env)
          end
        else
          return [
            STATUS__NOT_IMPLEMENTED,
            {"Content-Type" => "text/plain"},
            ["Resource found but it can be accessed only through %s" % @routes[route].keys.join(", ")]
          ]
        end
      end
    end
    [
      STATUS__NOT_FOUND,
      {"Content-Type" => "text/plain", "X-Cascade" => "pass"},
      ["Not Found: #{env[ENV__PATH_INFO]}"]
    ]
  ensure
    env[ENV__PATH_INFO] = path
    env[ENV__SCRIPT_NAME] = script_name
  end

  def sorted_routes
    @sorted_routes ||= @routes.keys.sort {|a,b| b.source.size <=> a.source.size}
  end

  def path_ok? path
    # comparing fixnums are much faster than comparing strings
    path.hash == (@empty_string_hash  ||= ''.hash ) || # replaces path.empty?
      path[0..0].hash == (@slash_hash ||= '/'.hash)    # replaces path =~ /\A\//
      # using path[0..0] instead of just path[0] for compatibility with ruby 1.8
  end

  def mount_controller controller, *roots, &setup
    return if @mounted_controllers.include?(controller)

    root = roots.shift
    if root || base_url.size > 0
      controller.remap!(base_url + root.to_s, *roots)
    end

    setup && controller.class_exec(&setup)
    @global_setup && controller.class_exec(&@global_setup)
    controller.mount! self
    @routes.update controller.routes
    controller.rewrite_rules.each {|(rule,proc)| rewrite_rule rule, &proc}

    @mounted_controllers << controller
  end

  def discover_controllers namespace = nil
    controllers = ObjectSpace.each_object(Class).
      select { |c| is_app?(c) }.reject { |c| [E].include? c }
    return controllers unless namespace

    namespace.is_a?(Regexp) ?
      controllers.select { |c| c.name =~ namespace } : controllers
  end

  def extract_controllers namespace
    if [Class, Module].include?(namespace.class)
      return discover_controllers.select {|c| c.name =~ /\A#{namespace}/}
    end
    discover_controllers namespace
  end
end
