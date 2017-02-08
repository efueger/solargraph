$LOAD_PATH.unshift File.dirname(__FILE__) + '/lib'
require 'solargraph/version'

Gem::Specification.new do |s|
  s.name        = 'solargraph'
  s.version     = Solargraph::VERSION
  s.date        = Date.today.strftime("%Y-%m-%d")
  s.summary     = "Solargraph for Ruby"
  s.description = "IDE tools for code analysis and autocompletion"
  s.authors     = ["Fred Snyder"]
  s.email       = 'admin@castwide.com'
  s.files       = Dir['lib'] + Dir['stubs']
  s.homepage    = 'http://castwide.com'
  s.license     = 'MIT'
  s.executables   = ['solargraph-ruby']
  s.required_ruby_version = '>= 1.9.3'
  s.add_runtime_dependency 'parser'
  s.add_runtime_dependency 'thor', '~> 0.19', '>= 0.19.4'
end