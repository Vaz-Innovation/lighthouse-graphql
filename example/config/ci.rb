# Run using bin/ci

CI.run do
  step 'Setup', 'bin/setup --skip-server'
  step 'Tests: end to end', 'bundle exec rspec'
  step 'Persisted queries: valid against the schema', 'bin/rails lighthouse:persisted_queries:verify'
end
