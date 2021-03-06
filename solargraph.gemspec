$LOAD_PATH.unshift File.dirname(__FILE__) + '/lib'
require 'solargraph/version'
require 'date'

Gem::Specification.new do |s|
  s.name        = 'solargraph'
  s.version     = Solargraph::VERSION
  s.date        = Date.today.strftime("%Y-%m-%d")
  s.summary     = "Solargraph for Ruby"
  s.description = "IDE tools for code analysis and autocompletion"
  s.authors     = ["Fred Snyder"]
  s.email       = 'admin@castwide.com'
  s.files       = Dir['lib/**/*'] + Dir['yardoc/**/*']
  s.homepage    = 'http://castwide.com'
  s.license     = 'MIT'
  s.executables   = ['solargraph']

  s.required_ruby_version = '>= 2.1'
  s.add_runtime_dependency 'parser', '~> 2.4'
  s.add_runtime_dependency 'thor', '~> 0.19', '>= 0.19.4'
  s.add_runtime_dependency 'sinatra', '~> 1.4'
  s.add_runtime_dependency 'yard', '~> 0.9'

  s.add_development_dependency 'rspec', '~> 3.5', '>= 3.5.0'
  s.add_development_dependency 'codeclimate-test-reporter', '~> 1.0', '>= 1.0.0'
end
