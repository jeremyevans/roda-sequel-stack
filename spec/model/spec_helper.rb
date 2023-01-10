require_relative '../coverage_helper'
ENV["RACK_ENV"] = "test"
require_relative '../../models'
raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?('test')

require_relative '../minitest_helper'

if ENV['NO_AUTOLOAD']
  Sequel::Model.freeze_descendents
  DB.freeze
end
