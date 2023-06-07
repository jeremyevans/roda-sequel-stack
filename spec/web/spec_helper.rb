# frozen_string_literal: true
require_relative '../coverage_helper'
ENV["RACK_ENV"] = "test"
require_relative '../../app'
Tilt.finalize!

raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?('test')

require 'capybara'
require 'capybara/dsl'
require 'rack/test'

Gem.suffix_pattern

require_relative '../minitest_helper'

App.plugin :not_found do
  raise "404 - File Not Found"
end
App.plugin :error_handler do |e|
  raise e
end

App.freeze if ENV['NO_AUTOLOAD']
Capybara.app = App.app
Capybara.exact = true

class Minitest::HooksSpec
  include Rack::Test::Methods
  include Capybara::DSL

  def app
    Capybara.app
  end

  after do
    Capybara.reset_sessions!
    Capybara.use_default_driver
  end
end
