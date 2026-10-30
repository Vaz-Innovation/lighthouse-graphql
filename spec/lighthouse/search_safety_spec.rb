# frozen_string_literal: true

require 'spec_helper'

# The search's safety, over generated fields (spec/support/search_safety.rb): for
# any field built from a data directive (@all, @paginate of each type, @first,
# a resolver of the app's own through enhance_builder; at the root or nested),
# field constraints (@builder, @whereAuth, `scopes:`, @orderBy(column:),
# @canQuery), argument filters (@eq, @in, @where, @trashed, @limit, an input
# object, defaults), a model setup (plain, a tenant's default scope with and
# without search_where, one read from the request, soft deletes, a
# search_results guard) and a search value ("a", "", null, none), EITHER the
# schema refuses to build, OR the request answers a client error, OR the
# records it answers with the search are a subset of those it answers without
# it (the same arguments, user and tenant), none of them another tenant's, and
# its total counts no more than the records it can load. The engine is a fake
# Searchkick whose index is the database, or a relational one, so the stale
# index window the guide documents does not arise.
#
# Deterministic: SEARCH_SAFETY_SEED picks the cases, SEARCH_SAFETY_CASES how
# many (420 by default, 30 of each shape); SEARCH_SAFETY_REPORT names a file for every violation.
RSpec.describe 'search safety, over generated fields' do
  let(:seed) { Integer(ENV.fetch('SEARCH_SAFETY_SEED', '20261030')) }
  let(:cases) { Integer(ENV.fetch('SEARCH_SAFETY_CASES', '420')) }

  before do
    stub_const('Searchkick', Module.new)
    Lighthouse::Config.authorizer = ->(_user, record, _ability) { !record.title.to_s.start_with?('secret') }
    Lighthouse::Config.on_error = ->(_error, _context) {}
    [['alpha', 1, nil, nil], ['apple', 2, nil, nil], ['avocado', 1, Time.current, nil], ['beta', 1, nil, 'hidden'],
     ['secret apple', 2, nil, 'invisible'], ['amber', 2, nil, nil]].each do |title, author, deleted_at, body|
      SafetyPlainPost.unscoped.create!(title: title, author_id: author, deleted_at: deleted_at, body: body)
    end
  end

  # :refused, :held, or what the case broke.
  def outcome(kase)
    Lighthouse::Config.search = kase.adapter
    schema = build_schema(kase.sdl)
    SearchSafety.violation(schema, kase) || :held
  rescue Lighthouse::DefinitionError => e
    schema ? "raised #{e.message[0, 160]}" : :refused
  rescue StandardError => e
    "raised #{e.class}: #{e.message[0, 160]}"
  end

  it 'never answers with a search more than the field allows, nor counts more than it can load' do
    random = Random.new(seed)
    outcomes = Array.new(cases) { |index| SearchSafety::Case.generate(random, index) }.map { |kase| [kase, outcome(kase)] }
    violations = outcomes.reject { |_kase, found| found.is_a?(Symbol) }.map { |kase, found| "#{found} -- #{kase.to_h}" }

    File.write(ENV['SEARCH_SAFETY_REPORT'], "#{outcomes.map(&:last).grep(Symbol).tally}\n#{violations.join("\n")}") if ENV['SEARCH_SAFETY_REPORT']
    expect(violations).to be_empty, "#{violations.size} of #{cases} cases broke the invariant (seed #{seed}):\n#{violations.first(20).join("\n")}"
  end
end
