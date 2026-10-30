# frozen_string_literal: true

# The cases of the search safety spec (spec/lighthouse/search_safety_spec.rb): a
# field built from a data directive, field constraints, argument filters and a
# model setup (spec/support/search_safety_models.rb), searched with a value, and
# what it answers checked against the same field without the search.
class Builders::SafetyOnlyA
  def self.call(relation, _value, _context) = relation.where('title LIKE ?', 'a%')
end

class Builders::SafetyMine
  def self.call(relation, _value, context) = relation.where(author_id: context[:current_user]&.id)
end

# An argument's @builder that asks Searchkick for its hits, not the records (`load: false`).
class Builders::SafetyUnloaded
  def self.call(target, _value, _context)
    target.options[:load] = false if target.is_a?(Lighthouse::Search::Query)
    target
  end
end

# A resolver of the app's own, which reads the search through enhance_builder.
class SafetyEnhanced
  def self.call(_obj, _args, ctx, resolve_info)
    found = resolve_info.enhance_builder(ctx[:safety_model].all)
    found.is_a?(Lighthouse::Search::Result) ? found.records(first: 100) : found.to_a
  end
end

class SafetyHolder
  def self.call(_obj, _args, _ctx) = {}
end

module SearchSafety
  MODELS = %w[SafetyPlainPost SafetyTenantPost SafetyTenantUnfilteredPost SafetyConditionalTenantPost SafetySoftPost SafetyUnscopedSoftPost
              SafetyGuardedPost].freeze
  TENANTED = %w[SafetyTenantPost SafetyTenantUnfilteredPost SafetyConditionalTenantPost].freeze
  PAGED = %i[paginate simple connection].freeze
  DATA = {
    all: '@all%<model>s', paginate: '@paginate%<model>s', simple: '@paginate(type: SIMPLE%<more>s)',
    connection: '@paginate(type: CONNECTION%<more>s)', field: '@field(resolver: "SafetyEnhanced")', first: '@first%<model>s'
  }.freeze
  SELECTIONS = {
    paginate: 'data { id } paginatorInfo { total }', simple: 'data { id }', connection: 'edges { node { id } } pageInfo { total }'
  }.freeze
  CONSTRAINTS = {
    only_a: '@builder(class: "SafetyOnlyA")', mine: '@builder(class: "SafetyMine")', where_auth: '@whereAuth(relation: "author")',
    order: '@orderBy(column: "title")', can_query: '@canQuery(ability: "view")', scopes: ''
  }.freeze
  ARGUMENTS = {
    eq: ['authorId: Int @eq(key: "author_id")', 'authorId: 1'],
    eq_default: ['authorId: Int = 1 @eq(key: "author_id")', nil],
    in: ['authors: [Int!] @in(key: "author_id")', 'authors: [2]'],
    where: ['minAuthor: Int @where(operator: "GTE", key: "author_id")', 'minAuthor: 2'],
    where_default: ['minAuthor: Int = 2 @where(operator: "GTE", key: "author_id")', nil],
    trashed: ['trashed: Trashed @trashed', 'trashed: %<trashed>s'],
    limit: ['max: Int @limit', 'max: 2'],
    input: ['filter: SafetyFilter', 'filter: { authorId: 2 }'],
    input_default: ['filter: SafetyFilter = { authorId: 1 }', nil],
    unloaded: ['raw: Boolean @builder(class: "SafetyUnloaded")', 'raw: true']
  }.freeze
  SEARCHES = ['"a"', '""', 'null', nil].freeze

  # The shapes the cases take in turn, so that each is as frequent as any other: an
  # engine, a data directive, and for a resolver of the app's own, whether it answers
  # the model's type or one the build cannot tell a model from (Hit).
  SHAPES = %i[searchkick relational].product(DATA.keys.flat_map { |data| data == :field ? [[data, false], [data, true]] : [[data, false]] })

  # The rows [title, author, trashed, body]; then what changed in the database
  # since the index that lags it (safety_stale_index) read them: an author, a
  # record trashed, one restored, one hidden, one gone, one new.
  ROWS = [['alpha', 1, false, nil], ['apple', 2, false, nil], ['avocado', 1, true, nil], ['beta', 1, false, 'hidden'],
          ['secret apple', 2, false, 'invisible'], ['amber', 2, false, nil]].freeze
  STALE = { 'alpha' => { author_id: 2 }, 'apple' => { deleted_at: Time.utc(2026) }, 'avocado' => { deleted_at: nil },
            'amber' => { body: 'hidden' }, 'beta' => :gone }.freeze

  # What each shape's cases add in turn, so each meets it as often: nothing, an
  # @builder asking for unloaded hits (`load: false`), an @canQuery (of the
  # first author's records) whose check the index outgrows before the page, a
  # stale index of a model Searchkick loads through `unscoped`.
  HAZARDS = [nil, :unloaded, :checked, :unscoped].freeze

  # The record the index and the database gain after a request's first search
  # (`growing`): between @canQuery's check and the page, which must not answer it.
  GROWN = { title: 'secret apricot', author_id: 1 }.freeze

  # One generated case. `user`: who sends the request, under tenant 1: its own
  # tenant's author, or another. `stale`: does the index lag the database?
  # `growing`: do they gain GROWN after the first search? Most cases have a
  # constraint, and few or no argument filters, which a search outside the
  # database mostly refuses.
  Case = Struct.new(:engine, :model, :data, :nested, :named_model, :hit_type, :constraints, :arguments, :trashed, :search, :user, :stale,
                    :growing, keyword_init: true) do
    def self.generate(random, index)
      engine, (data, hit_type) = SHAPES[index % SHAPES.size]
      kase = new(engine: engine, data: data, hit_type: hit_type, model: MODELS.sample(random: random), nested: random.rand < 0.3,
                 named_model: random.rand < 0.5, constraints: CONSTRAINTS.keys.sample([0, 1, 1, 2].sample(random: random), random: random),
                 arguments: ARGUMENTS.keys.sample([0, 0, 1, 2].sample(random: random), random: random),
                 trashed: %w[WITH ONLY WITHOUT].sample(random: random), search: SEARCHES.sample(random: random),
                 user: [1, 2].sample(random: random), stale: random.rand < 0.5, growing: random.rand < 0.5)
      kase.with_hazard(HAZARDS[(index / SHAPES.size) % HAZARDS.size])
    end

    # The case, with the hazard of its turn added (HAZARDS).
    def with_hazard(hazard)
      case hazard
      when :unloaded then arguments << :unloaded
      when :checked then (constraints << :can_query) && (arguments << :eq) && (self.growing = true)
      when :unscoped then (self.model = 'SafetyUnscopedSoftPost') && (self.stale = true)
      end
      constraints.uniq!
      arguments.uniq! { |key| key.to_s.delete_suffix('_default') }
      self
    end

    def adapter = engine == :searchkick ? Lighthouse::Search::Searchkick.new : FakeSearch::Relational.new(MODELS.map(&:constantize))

    def sdl
      <<~GRAPHQL
        type #{model} { id: ID! title: String! }
        type Hit { id: ID! }
        type Holder { #{nested ? field : 'id: ID'} }
        input SafetyFilter { authorId: Int @eq(key: "author_id") }
        type Query { #{nested ? 'holder: Holder @field(resolver: "SafetyHolder")' : field} }
      GRAPHQL
    end

    # The same field without the search, nor @limit, which cuts what each answers in its own order.
    def unsearched = dup.tap { |copy| copy.arguments = arguments - [:limit] }

    def query(searching)
      field = "f#{"(#{values(searching).join(', ')})" unless values(searching).empty?} { #{SELECTIONS.fetch(data, 'id')} }"
      nested ? "{ holder { #{field} } }" : "{ #{field} }"
    end

    def values(searching)
      values = arguments.filter_map { |key| ARGUMENTS.fetch(key).last }.map { |value| format(value, trashed: trashed) }
      values.unshift("search: #{search}") if searching && search
      PAGED.include?(data) ? ['first: 100', *values] : values
    end

    private

    def field
      arguments_sdl = ['search: String @search', *arguments.map { |key| ARGUMENTS.fetch(key).first }].join(', ')
      constraints_sdl = constraints.map { |key| CONSTRAINTS.fetch(key) }.join(' ')
      "f(#{arguments_sdl}): #{data == :first ? type : "[#{type}!]!"} #{data_sdl} #{constraints_sdl}"
    end

    def type = data == :field && hit_type ? 'Hit' : model

    def data_sdl
      model_arg = %(model: "#{model}") if named_model || nested
      scopes = 'scopes: ["visible"]' if constraints.include?(:scopes) && data != :field
      own = [model_arg, scopes].compact.join(', ')
      format(DATA.fetch(data), model: own.empty? ? '' : "(#{own})", more: own.empty? ? '' : ", #{own}")
    end
  end
end

# What a case answers, and what it breaks of the invariant.
module SearchSafety::Invariant
  module_function

  # The rows, in the database and the index that lags it.
  def seed!
    SearchSafety::ROWS.each do |title, author, trashed, body|
      SafetyPlainPost.unscoped.create!(title: title, author_id: author, deleted_at: (Time.utc(2025) if trashed), body: body)
    end
    SafetyStaleRow.delete_all
    SafetyPlainPost.unscoped.each { |post| SafetyStaleRow.create!(post.attributes) }
    SearchSafety::STALE.each do |title, change|
      post = SafetyPlainPost.unscoped.find_by!(title: title)
      change == :gone ? post.delete : post.update!(change)
    end
    SafetyPlainPost.unscoped.create!(title: 'apricot', author_id: 1)
  end

  # [ids, total] the field answers, or :error for a client error.
  def answer(schema, kase, searching) = together(schema, [kase], searching).first

  # What the cases answer as the queries of one multiplex, which share one context Hash.
  def together(schema, kases, searching)
    context = { current_user: SafetyPlainPost.unscoped.new(id: kases.first.user), safety_model: kases.first.model.constantize }
    queries = kases.map { |kase| { query: kase.query(searching), context: context } }
    SafetyCurrent.as(1) { schema.multiplex(queries) }.zip(kases).map do |result, kase|
      result = result.to_h
      next :error if result['errors']

      read(kase, kase.nested ? result.dig('data', 'holder', 'f') : result.dig('data', 'f'))
    end
  end

  def read(kase, found)
    return [ids([found].compact), nil] if kase.data == :first
    return [ids(found), nil] unless found.is_a?(Hash)

    [ids(found['data'] || found['edges'].pluck('node')), found.dig('paginatorInfo', 'total') || found.dig('pageInfo', 'total')]
  end

  def ids(rows) = rows.map { |row| row['id'].to_i }

  # What the case breaks of the invariant, or nil. Without the search first, so
  # that a record the index gains after the first search (GROWN) is one the
  # field does not answer without it.
  def violation(schema, kase)
    FakeSearch::Indexed.as(kase.stale) do
      unsearched = answer(schema, kase.unsearched, false)
      searched = growing(kase) { answer(schema, kase, true) }
      next nil if searched == :error
      next "answers with the search what it refuses without: #{searched.first}" if unsearched == :error

      subset(searched.first, unsearched.first) || tenant(kase, searched.first) || count(kase, *searched) || shared(schema, kase, searched)
    end
  end

  # The block, with the index and the database gaining GROWN after its first
  # search, when the case says so; GROWN is gone after it.
  def growing(kase, &block)
    return yield unless kase.growing

    FakeSearch::Indexed.growing(-> { SafetyStaleRow.create!(SafetyPlainPost.unscoped.create!(SearchSafety::GROWN).attributes) }, &block)
  ensure
    [SafetyPlainPost.unscoped, SafetyStaleRow].each { |rows| rows.where(title: SearchSafety::GROWN[:title]).delete_all }
  end

  def subset(ids, allowed) = ("answers #{ids - allowed} with the search, not without it" unless (ids - allowed).empty?)

  def tenant(kase, ids)
    return nil if SearchSafety::TENANTED.exclude?(kase.model) || SafetyPlainPost.unscoped.where(id: ids).pluck(:author_id).all?(1)

    "answers another tenant's records: #{ids}"
  end

  # The total counts no more than the records it can load; an index that lags
  # the database may count each record that changed since.
  def count(kase, ids, total)
    stale = kase.stale ? SearchSafety::STALE.size : 0
    return nil if total.nil? || kase.arguments.include?(:limit) || total <= ids.size + stale

    "counts #{total} for #{ids.size} records it can load"
  end

  # In a multiplex with another search, sharing one context Hash, the case answers what it answers alone.
  def shared(schema, kase, searched)
    return nil if kase.search.nil? || kase.search == 'null'

    other = kase.dup.tap { |copy| copy.search = kase.search == '"a"' ? '"p"' : '"a"' }
    alone = [searched, answer(schema, other, true)]
    found = together(schema, [kase, other], true)
    "answers #{found} in a multiplex sharing its context, #{alone} alone" unless found == alone
  end
end
