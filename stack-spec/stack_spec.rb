# frozen_string_literal: true
ENV['MT_NO_PLUGINS'] = '1' # Work around stupid autoloading of plugins
require 'minitest/global_expectations/autorun'

require 'fileutils'
require 'net/http'
require 'uri'
require 'find'

TEST_STACK_DIR = 'test-stack'.freeze
RUBY = ENV['RUBY'] || (RUBY_ENGINE == 'jruby' ? 'jruby' : 'ruby')
RAKE = ENV['RAKE'] || 'rake'
PUMA = ENV['PUMA'] || 'puma'
SEQUEL = ENV['SEQUEL'] || 'sequel'

describe 'roda-sequel-stack' do
  after do
    FileUtils.remove_dir(TEST_STACK_DIR) if File.directory?(TEST_STACK_DIR)
  end

  def progress(object)
    if ENV['DEBUG']
      p object
    else
      print '.'
    end
  end

  if RUBY_ENGINE == 'jruby'
    db_url = 'jdbc:sqlite:db.sqlite3_test'
    def command(args)
      case args[0]
      when 'git', RUBY
        # nothing
      else
        args.unshift('-S')
        args.unshift(RUBY)
      end
      progress(args)
      args
    end
  else
    db_url = 'sqlite://db.sqlite3_test'
    def command(args)
      progress(args)
      args
    end
  end

  def run_puma(*args)
    read, write = IO.pipe
    args = [PUMA, *args]
    command(args)
    pid = Process.spawn(*args, out: write, err: write)
    read.each_line do |line|
      progress(line)
      break if line =~ /Use Ctrl-C to stop/
    end

    Net::HTTP.get(URI('http://127.0.0.1:9292/')).must_include 'Hello World!'
    Net::HTTP.get(URI('http://127.0.0.1:9292/prefix1')).must_include 'Model1: M1'
  ensure
    if pid
      Process.kill(:INT, pid)
      Process.wait(pid)
    end
    read.close if read
    write.close if write
  end

  # Run command capturing stderr/stdout
  def run_cmd(*cmds)
    env = cmds.shift if cmds.first.is_a?(Hash)
    command(cmds)
    cmds.unshift(env) if env
    read, write = IO.pipe
    system(*cmds, out: write, err: write).tap{|x| unless x; write.close; p cmds; puts read.read; end}.must_equal true
    write.close
    progress(read.read)
    read.close
  end

  def rewrite(filename)
    File.binwrite(filename, yield(File.binread(filename)))
  end

  it 'should work after rake setup is run' do
    run_cmd("git", "clone", ".", TEST_STACK_DIR)

    Dir.chdir(TEST_STACK_DIR) do
      run_cmd(RAKE, 'setup[FooBarApp]')
      environments = %w[development test production].freeze
      rewrite(".env.rb") do |content|
        content.gsub(%r"postgres:///foo_bar_app_(\w+)\?user=foo_bar_app", "#{db_url}_\\1")
      end

      files = []
      directories = []
      Find.find('.').each do |f|
        if File.directory?(f)
          Find.prune if f == './.git'
          directories << f
        else
          files << f
        end
      end

      directories.sort.must_equal  [
        ".", "./assets", "./assets/css", "./migrate", "./models", "./public", "./routes",
        "./spec", "./spec/model", "./spec/web", "./views"
      ]
      files.sort.must_equal [
        "./.env.rb", "./.gitignore", "./Gemfile", "./README.rdoc", "./Rakefile", "./app.rb",
        "./assets/css/app.scss", "./config.ru", "./db.rb", "./migrate/001_tables.rb",
        "./models.rb", "./models/model1.rb", "./routes/prefix1.rb", "./spec/coverage_helper.rb",
        "./spec/minitest_helper.rb", "./spec/model.rb", "./spec/model/model1_spec.rb",
        "./spec/model/spec_helper.rb", "./spec/web.rb", "./spec/web/prefix1_spec.rb",
        "./spec/web/spec_helper.rb", "./views/index.erb", "./views/layout.erb"
      ]

      rewrite('migrate/001_tables.rb') do |s|
        s.sub("primary_key :id", "primary_key :id; String :name")
      end

      # Test migrations
      run_cmd(RAKE, 'test_up', 'dev_up')
      run_cmd(RAKE, 'test_down', 'dev_down')
      run_cmd(RAKE, 'test_bounce', 'dev_bounce')
      run_cmd(RAKE, 'prod_up')

      environments.each do |env|
        run_cmd({"RACK_ENV"=>env}, RUBY, "-r", "./db", "-e", "raise \"migration rake tasks not successful for #{env} environment, tables: \#{DB.tables.sort.join(', ')}\" unless DB.tables.sort == [:model1s, :schema_info]")
      end
      
      Dir.mkdir('views/prefix1')
      File.binwrite('views/prefix1/p1.erb', "<p>Model1: <%= Model1.first.name %></p>")
      rewrite('routes/prefix1.rb'){|s| s.sub("# /prefix1 branch handling", "r.get{view 'p1'}")}
      environments.each do |env|
        run_cmd(SEQUEL, "#{db_url}_#{env}", '-c', "DB[:model1s].insert(name: 'M1')")
        run_cmd(SEQUEL, "#{db_url}_#{env}", '-c', "raise \"invalid count for models in #{env} environment\" unless DB[:model1s].count == 1")
      end

      # Test running in development mode
      run_puma

      # Test annotation
      run_cmd(RAKE, 'annotate')
      File.read("models/model1.rb").must_include "# Table: model1s"

      # Test running with refrigerator
      rewrite('config.ru') do |s|
        s.sub(/^#freeze_core/, "freeze_core").
          gsub("#require", "require").
          sub('#Gem', 'Gem')
      end
      run_puma('-e', 'production')

      # Test running full specs
      run_cmd(RAKE)
      run_cmd(RAKE, 'model_spec')
      run_cmd(RAKE, 'web_spec')

      # Test running individual spec files
      run_cmd(RUBY, 'spec/model/model1_spec.rb')
      run_cmd(RUBY, 'spec/web/prefix1_spec.rb')

      unless RUBY_ENGINE == 'jruby'
        # Test running coverage
        run_cmd(RAKE, 'spec_cov')
        coverage = File.binread('coverage/index.html')
        coverage.must_include('lines covered')
        coverage.must_include('lines missed')
        coverage.must_include('branches covered')
        coverage.must_include('branches missed')
      end
    end
  end
end
