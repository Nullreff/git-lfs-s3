require 'rack/test'
require 'rspec'
require File.expand_path '../../lib/git-lfs-s3.rb', __FILE__

ENV['RACK_ENV'] = 'test'

module RSpecMixin
  include Rack::Test::Methods
  def app() GitLfsS3::Application end
end

RSpec.configure do |config|
  config.include RSpecMixin
  config.order = :random
  config.expect_with :rspec do |e|
    e.syntax = :expect
  end
  config.mock_with :rspec do |m|
    m.syntax = :expect
    m.verify_partial_doubles = true
  end
end
