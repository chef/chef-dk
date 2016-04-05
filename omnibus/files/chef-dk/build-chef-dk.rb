require "shellwords"
require "pathname"
require "bundler"
require_relative "../chef-dk-gem/build-chef-dk-gem"

# We use this to break up the `build` method into readable parts
module BuildChefDK
  include BuildChefDKGem

  # Some gems are part of our bundle (must be installed) but not important
  # enough to lock. List those here.
  GEMS_ALLOWED_TO_FLOAT = [
    "rubocop", # different projects disagree in their dev dependencies
    "unicode-display_width", # dep of rubocop
  ]

  def create_bundle_config(gemfile, without: [ "development" ], retries: nil, jobs: nil, frozen: nil)
    if without
      without = without.dup
      # no_aix, no_windows groups
      without << "no_#{Omnibus::Ohai["platform"]}"
    end

    bundle_config = File.expand_path("../.bundle/config", gemfile)

    block "Put build config into #{bundle_config}: #{ { without: without, retries: retries, jobs: jobs, frozen: frozen } }" do
      # bundle config build.nokogiri #{nokogiri_build_config} messes up the line,
      # so we write it directly ourselves.
      new_bundle_config = "---\n"
      new_bundle_config << "BUNDLE_WITHOUT: #{Array(without).join(":")}\n" if without
      new_bundle_config << "BUNDLE_RETRY: #{retries}\n" if retries
      new_bundle_config << "BUNDLE_JOBS: #{jobs}\n" if jobs
      new_bundle_config << "BUNDLE_FROZEN: '1'\n" if frozen
      all_install_args.each do |gem_name, install_args|
        new_bundle_config << "BUNDLE_BUILD__#{gem_name.upcase}: #{install_args}\n"
      end
      create_file(bundle_config) { new_bundle_config }
    end
  end

  #
  # Get the (possibly platform-specific) path to the Gemfile.
  # /var/omnibus/cache/src/chef-dk/Gemfile or
  # /var/omnibus/cache/src/chef-dk/Gemfile.windows
  #
  def chefdk_gemfile
    gemfile = File.join(project_dir, "Gemfile")
    # Check for platform specific version
    platform_gemfile = "#{gemfile}.#{Omnibus::Ohai["platform"]}"
    if File.exist?(platform_gemfile)
      gemfile = platform_gemfile
    end
    gemfile
  end

  #
  # Get the path to the top level shared Gemfile included by all individual
  # Gemfiles
  #
  def shared_gemfile
    File.join(install_dir, "Gemfile")
  end

  #
  # Some gems we installed don't end up in the `gem list` due to the fact that
  # they have git sources (`gem 'chef', github: 'chef/chef'`) or paths (`gemspec`
  # or `gem 'chef-config', path: 'chef-config'`). To get them in there, we need
  # to go through these gems, run `rake install` from their top level, and
  # then delete the git cached versions.
  #
  # Once we finish with all this, we update the Gemfile that will end up in the
  # chef-dk so that it doesn't have git or path references anymore.
  #
  def properly_reinstall_git_and_path_sourced_gems
    chefdk_env = env.dup.merge("BUNDLE_GEMFILE" => chefdk_gemfile)

    # Reinstall git-sourced or path-sourced gems, and delete the originals
    block "Reinstall git-sourced gems properly" do
      # Grab info about the gem environment so we can make decisions
      gemdir = shellout!("#{gem_bin} environment gemdir", env: env).stdout.chomp
      gem_install_dir = File.join(gemdir, "gems")

      # bundle list --paths gets us the list of gem install paths. Get the ones
      # that are installed local (git and path sources like `gem :x, github: 'chef/x'`
      # or `gem :x, path: '.'` or `gemspec`). To do this, we just detect which ones
      # have properly-installed paths (in the `gems` directory that shows up when
      # you run `gem list`).
      locally_installed_gems = shellout!("#{bundle_bin} list --paths", env: chefdk_env, cwd: project_dir).
        stdout.lines.select { |gem_path| !gem_path.start_with?(gem_install_dir) }

      # Install the gems for real using `rake install` in their directories
      locally_installed_gems.each do |gem_path|
        gem_path = gem_path.chomp
        # We use the already-installed bundle to rake install, because (hopefully)
        # just rake installing doesn't require anything special.
        log.info(log_key) { "Properly installing git or path sourced gem #{gem_path} using rake install" }
        shellout!("#{bundle_bin} exec #{rake_bin} install", env: chefdk_env, cwd: gem_path)
      end
    end
  end

  def install_shared_gemfile
    shared_gemfile = self.shared_gemfile
    chefdk_env = env.dup.merge("BUNDLE_GEMFILE" => chefdk_gemfile)

    # Show the config for good measure
    bundle "config", env: chefdk_env

    # Make `Gemfile` point to these by removing path and git sources and pinning versions.
    block "Rewrite Gemfile using all properly-installed gems" do
      gem_pins = ""
      result = []
      shellout!("#{bundle_bin} list", env: chefdk_env).stdout.lines.map do |line|
        if line =~ /^\s*\*\s*(\S+)\s+\((\S+).*\)\s*$/
          name, version = $1, $2
          # rubocop is an exception, since different projects disagree
          next if GEMS_ALLOWED_TO_FLOAT.include?(name)
          gem_pins << "override_gem #{name.inspect}, #{version.inspect}\n"
        end
      end

      create_file(shared_gemfile) { <<-EOM }
        # Meant to be included in component Gemfiles at the end with:
        #
        #     instance_eval(IO.read("#{install_dir}/Gemfile"), "#{install_dir}/Gemfile")
        #
        # Override any existing gems with our own.
        def override_gem(name, *args, &block)
          # If the Gemfile re-specifies something in our lockfile, ignore it.
          current = dependencies.find { |dep| dep.name == name }
          dependencies.delete(current) if current
          gem(name, *args, &block)
        end
        #{gem_pins}
      EOM
    end

    shared_gemfile_env = env.dup.merge("BUNDLE_GEMFILE" => shared_gemfile)

    # Create a `Gemfile.lock` at the final location
    bundle "lock", env: shared_gemfile_env

    # Freeze the location's Gemfile.lock.
    create_bundle_config(shared_gemfile, frozen: true)

    # Clear the now-unnecessary git caches, cached gems, and git-checked-out gems
    block "Delete bundler git cache and git installs" do
      gemdir = shellout!("#{gem_bin} environment gemdir", env: env).stdout.chomp
      remove_file "#{gemdir}/cache"
      remove_file "#{gemdir}/bundler"
    end
  end

  # appbundle the gems, making /opt/chefdk/bin/<binary> do the superfast pinning
  # thing.
  #
  # To protect the app from loading the wrong versions of things, it uses
  # appbundler against the resulting file. NOTE: if the user's Gemfile has gems
  # in the
  #
  # Relocks the Gemfiles inside the specified gems (e.g. berkshelf, test-kitchen,
  # chef) to use the chef-dk distribution's chosen gems.
  def appbundle_gems(gems)
    shared_gemfile = self.shared_gemfile

    # re-lock the Gemfile to the build
    # Ensure the main bin dir exists
    bin_dir = File.join(install_dir, "bin")
    mkdir(bin_dir)

    # For each gem, update the Gemfile to restrict to built versions so that
    # bundle installs will do the right thing
    gems.each do |gem_name|
      block "Lock down and appbundle the #{gem_name} gem" do
        installed_path = shellout!("#{bundle_bin} show #{gem_name}").stdout.chomp
        installed_gemfile = File.join(installed_path, "Gemfile")

        #
        # Include the main distribution Gemfile in the gem's Gemfile
        #
        # NOTE: if this fails and the build retries, you will see this multiple
        # times in the file.
        #
        distribution_gemfile = Pathname(shared_gemfile).relative_path_from(Pathname(installed_gemfile)).to_s
        gemfile_text = IO.read(installed_gemfile)
        gemfile_text << <<-EOM.gsub(/^\s+/, '')
          # Lock gems that are part of the distribution
          distribution_gemfile = File.expand_path(#{distribution_gemfile.inspect}, __FILE__)
          instance_eval(IO.read(distribution_gemfile), distribution_gemfile)
        EOM
        create_file(installed_gemfile) { gemfile_text }

        # Remove the gemfile.lock
        remove_file("#{installed_gemfile}.lock") if File.exist?("#{installed_gemfile}.lock")

        # If it's frozen, make it not be.
        shellout!("#{bundle_bin} config --delete frozen")

        # This could be changed to `bundle install` if we wanted to actually
        # install extra deps out of their gemfile ...
        shellout!("#{bundle_bin} lock", env: env, cwd: installed_path)
        # bundle lock doesn't always tell us when it fails, so we have to check :/
        unless File.exist?("#{installed_gemfile}.lock")
          raise "bundle lock failed: no #{installed_gemfile}.lock created!"
        end

        # Ensure all the gems we need are actually installed (if the bundle adds
        # something, we need to know about it so we can include it in the main
        # solve).
        # Save bundle config and modify to use --without development before checking
        bundle_config = File.expand_path("../.bundle/config", installed_gemfile)
        orig_config = IO.read(bundle_config) if File.exist?(bundle_config)
        # "test", "changelog" and "guard" come from berkshelf, "maintenance" comes from chef
        shellout!("#{bundle_bin} config --local without development:test:guard:maintenance:changelog:no_#{Omnibus::Ohai["platform"]}", env: env, cwd: installed_path)
        shellout!("#{bundle_bin} config --local frozen 1")

        shellout!("#{bundle_bin} check", env: env, cwd: installed_path)

        # appbundle the gem
        appbundler_args = [ installed_path, bin_dir, gem_name ]
        appbundler_args = appbundler_args.map { |a| ::Shellwords.escape(a) }
        shellout!("#{appbundler_bin} #{appbundler_args.join(" ")}", env: env, cwd: installed_path)

        # Restore bundle config
        if orig_config
          create_file(bundle_config) { orig_config }
        else
          remove_file bundle_config
        end
      end
    end
  end
end
