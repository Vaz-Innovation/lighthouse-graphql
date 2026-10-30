# The suite's database: a throwaway PostgreSQL that Testcontainers starts in Docker,
# on a host port Docker picks, so it never clashes with a server already running.
# DATABASE_URL skips it and names the database instead: CI's MySQL run, or a server
# of your own. It must be set before Rails reads config/database.yml, so rails_helper
# requires this file first; maintain_test_schema! then loads db/schema.rb into it.
unless ENV['DATABASE_URL']
  require 'testcontainers/postgres'

  database = 'lighthouse_example_test'
  postgres = Testcontainers::PostgresContainer.new('postgres:16', database: database)
  # testcontainers-postgres 0.2 sets POSTGRES_DATABASE, which the image ignores: without
  # POSTGRES_DB the database is never created, and the health check waits for it in vain.
  postgres.add_env('POSTGRES_DB', database)
  postgres.start
  ENV['DATABASE_URL'] = postgres.database_url
  at_exit { postgres.remove(force: true) }
end
