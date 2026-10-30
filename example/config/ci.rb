# Run using bin/ci

CI.run do
  # Not bin/setup: it prepares the development database, and the suite brings its
  # own PostgreSQL (spec/postgres_container.rb).
  step 'Dependencies', 'bundle check || bundle install'
  step 'Tests: end to end', 'bundle exec rspec'
  step 'Persisted queries: valid against the schema', 'bin/rails lighthouse:persisted_queries:verify'
end
