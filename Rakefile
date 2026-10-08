# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  task(:rubocop) { warn "rubocop is not installed" }
end

begin
  require "yard"
  YARD::Rake::YardocTask.new(:doc) { |t| t.files = ["lib/**/*.rb"] }
rescue LoadError
  task(:doc) { warn "yard is not installed" }
end

task default: %i[test rubocop]
