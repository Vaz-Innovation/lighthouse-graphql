# frozen_string_literal: true

# How Query.everything ranks the multisearch documents (Post and User, @search over the
# SearchResult union): PostgreSQL's full-text search, "Rail" finding "Rails" as Post's own scope does.
PgSearch.multisearch_options = { using: { tsearch: { prefix: true } } }
