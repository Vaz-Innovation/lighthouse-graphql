# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'soft deletes' do
  def run(schema, query)
    schema.execute(query).to_h
  end

  def names(result, field)
    result.dig('data', field).map { |row| row['name'] }
  end

  let(:types) do
    <<~GRAPHQL
      type SoftTask { id: ID! name: String }
      type HiddenTask { id: ID! name: String }
      type ParanoidItem { id: ID! name: String }
      type DiscardItem { id: ID! name: String }
      type DiscardKeptItem { id: ID! name: String }
    GRAPHQL
  end

  describe '@softDeletes (the schema)' do
    it 'adds the trashed argument and the Trashed enum, and consumes the directive' do
      schema = build_schema("#{types}\ntype Query { tasks: [SoftTask!]! @all @softDeletes }")

      argument = schema.query.fields['tasks'].arguments['trashed']
      expect(argument.type.graphql_name).to eq('Trashed')
      expect(argument.ast_node.directives.map(&:name)).to eq(['trashed'])
      expect(schema.types['Trashed'].values.keys).to eq(%w[ONLY WITH WITHOUT])
      expect(schema.types['Trashed'].description).to eq('Specify if you want to include or exclude trashed results from a query.')
      expect(schema.query.fields['tasks'].ast_node.directives.map(&:name)).to eq(['all'])
    end

    it 'defines Trashed once for any number of fields' do
      schema = build_schema(<<~GRAPHQL)
        #{types}
        type Query {
          tasks: [SoftTask!]! @all @softDeletes
          items: [ParanoidItem!]! @all @softDeletes
          paged: [SoftTask!]! @paginate @softDeletes
        }
      GRAPHQL

      expect(schema.to_definition.scan(/^enum Trashed\b/).size).to eq(1)
      expect(schema.query.fields.values.map { |field| field.arguments.key?('trashed') }).to all(be(true))
    end

    it 'adds the argument after the pagination arguments' do
      schema = build_schema("#{types}\ntype Query { paged: [SoftTask!]! @paginate @softDeletes }")

      expect(schema.query.fields['paged'].arguments.keys).to eq(%w[first page trashed])
    end

    it 'keeps the Trashed enum the app declares' do
      schema = build_schema(<<~GRAPHQL)
        #{types}
        "Mine."
        enum Trashed { ONLY WITH WITHOUT }
        type Query { tasks: [SoftTask!]! @all @softDeletes }
      GRAPHQL

      expect(schema.to_definition.scan(/^enum Trashed\b/).size).to eq(1)
      expect(schema.types['Trashed'].description).to eq('Mine.')
    end

    it 'does not add an argument the field already declares' do
      schema = build_schema(<<~GRAPHQL)
        #{types}
        type Query { tasks(trashed: Trashed @trashed): [SoftTask!]! @all @softDeletes }
      GRAPHQL

      expect(schema.query.fields['tasks'].arguments.keys).to eq(['trashed'])
    end

    it 'defines Trashed for a hand-written @trashed argument' do
      schema = build_schema(<<~GRAPHQL)
        #{types}
        type Query { tasks(archive: Trashed @trashed): [SoftTask!]! @all }
      GRAPHQL

      expect(schema.types['Trashed'].values.keys).to eq(%w[ONLY WITH WITHOUT])
    end

    it 'adds nothing to a schema that does not use it' do
      sdl = 'type Query { a: Int }'

      expect(Lighthouse::GraphQL::Directives::SoftDeletesDirective.manipulate(sdl)).to eq(sdl)
      expect(build_schema(sdl).types).not_to have_key('Trashed')
    end

    it 'puts the directive definitions in the injected SDL, and the enum in the IDE helper types' do
      sdl = "#{types}\ntype Query { tasks: [SoftTask!]! @all @softDeletes }"

      directives = Lighthouse::IdeHelper.directives_sdl(sdl)
      expect(directives).to include('directive @softDeletes on FIELD_DEFINITION', 'directive @trashed on', 'directive @withoutGlobalScopes(',
                                    'directive @forceDelete(', 'directive @restore(')
      expect(Lighthouse::IdeHelper.programmatic_types_sdl(sdl)).to include('enum Trashed')
    end
  end

  describe '@trashed' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        #{types}
        type Query {
          softTasks: [SoftTask!]! @all(model: "SoftTask") @softDeletes
          hiddenTasks: [HiddenTask!]! @all @softDeletes
          paranoidItems: [ParanoidItem!]! @all @softDeletes
          discardItems: [DiscardItem!]! @all @softDeletes
          discardKeptItems: [DiscardKeptItem!]! @all @softDeletes
        }
      GRAPHQL
    end

    # Every strategy: [field, model, whether a client that omits `trashed` sees the trashed record].
    {
      'a deleted_at column' => ['softTasks', SoftTask, :deleted_at, true],
      'a deleted_at column with a default scope' => ['hiddenTasks', HiddenTask, :deleted_at, false],
      'paranoia' => ['paranoidItems', ParanoidItem, :deleted_at, false],
      'discard' => ['discardItems', DiscardItem, :discarded_at, true],
      'discard with a default scope' => ['discardKeptItems', DiscardKeptItem, :discarded_at, false]
    }.each do |strategy, (field, model, column, shows_trashed)|
      context "with #{strategy}" do
        before do
          model.unscoped.create!(name: 'kept')
          model.unscoped.create!(name: 'trashed', **{ column => Time.current })
        end

        it 'returns only the trashed ones for ONLY' do
          expect(names(run(schema, "{ #{field}(trashed: ONLY) { name } }"), field)).to eq(['trashed'])
        end

        it 'returns both for WITH' do
          expect(names(run(schema, "{ #{field}(trashed: WITH) { name } }"), field)).to contain_exactly('kept', 'trashed')
        end

        it 'returns only the others for WITHOUT' do
          expect(names(run(schema, "{ #{field}(trashed: WITHOUT) { name } }"), field)).to eq(['kept'])
        end

        it "leaves the model's own behaviour alone when omitted" do
          expected = shows_trashed ? %w[kept trashed] : ['kept']

          expect(names(run(schema, "{ #{field} { name } }"), field)).to match_array(expected)
        end
      end
    end

    it 'applies to a model that does not support soft deletes as an error' do
      Widget.create!(name: 'w')
      schema = build_schema(<<~GRAPHQL)
        type Widget { id: ID! name: String }
        type Query { widgets: [Widget!]! @all @softDeletes }
      GRAPHQL

      expect(run(schema, '{ widgets(trashed: ONLY) { name } }')['errors'].first['message'])
        .to eq('Model Widget does not support soft deletes (no paranoia, discard or deleted_at column; see Config.soft_deletes).')
      expect(names(run(schema, '{ widgets { name } }'), 'widgets')).to eq(['w'])
    end

    it 'composes with the other filters' do
      SoftTask.create!(name: 'a')
      SoftTask.create!(name: 'a', deleted_at: Time.current)
      SoftTask.create!(name: 'b', deleted_at: Time.current)
      schema = build_schema(<<~GRAPHQL)
        #{types}
        type Query { softTasks(name: String @eq): [SoftTask!]! @all @softDeletes }
      GRAPHQL

      result = run(schema, '{ softTasks(name: "a", trashed: ONLY) { id name } }')

      expect(result['data']['softTasks'].size).to eq(1)
      expect(SoftTask.find(result['data']['softTasks'].first['id']).deleted_at).not_to be_nil
    end

    describe 'with the other query directives' do
      let(:schema) do
        build_schema(<<~GRAPHQL)
          #{types}
          type Query {
            hiddenTasks: [HiddenTask!]! @paginate(defaultCount: 10) @softDeletes
            paranoidItems: [ParanoidItem!]! @paginate(type: CONNECTION, defaultCount: 10) @softDeletes
            hiddenTask(id: ID! @eq): HiddenTask @find @softDeletes
            firstHiddenTask: HiddenTask @first @softDeletes
            hiddenTaskCount: Int! @count(model: "HiddenTask") @softDeletes
          }
        GRAPHQL
      end
      let!(:kept) { HiddenTask.create!(name: 'kept') }
      let!(:trashed) { HiddenTask.unscoped.create!(name: 'trashed', deleted_at: Time.current) }

      it 'filters @paginate' do
        result = run(schema, '{ hiddenTasks(trashed: ONLY) { data { name } paginatorInfo { total } } }')

        expect(result['data']['hiddenTasks']['data']).to eq([{ 'name' => 'trashed' }])
        expect(result['data']['hiddenTasks']['paginatorInfo']['total']).to eq(1)
        expect(run(schema, '{ hiddenTasks { paginatorInfo { total } } }').dig('data', 'hiddenTasks', 'paginatorInfo', 'total')).to eq(1)
        with = run(schema, '{ hiddenTasks(trashed: WITH) { paginatorInfo { total } } }')
        expect(with.dig('data', 'hiddenTasks', 'paginatorInfo', 'total')).to eq(2)
      end

      it 'filters a @paginate connection with paranoia' do
        ParanoidItem.create!(name: 'kept')
        ParanoidItem.create!(name: 'gone').destroy

        result = run(schema, '{ paranoidItems(trashed: ONLY) { edges { node { name } } } }')

        expect(result.dig('data', 'paranoidItems', 'edges')).to eq([{ 'node' => { 'name' => 'gone' } }])
      end

      it 'filters @find, which is otherwise batched by id' do
        expect(run(schema, "{ hiddenTask(id: #{trashed.id}) { name } }")['data']['hiddenTask']).to be_nil
        expect(run(schema, "{ hiddenTask(id: #{trashed.id}, trashed: WITH) { name } }")['data']['hiddenTask']).to eq('name' => 'trashed')
        expect(run(schema, "{ hiddenTask(id: #{kept.id}, trashed: ONLY) { name } }")['data']['hiddenTask']).to be_nil
      end

      it 'filters @first' do
        expect(run(schema, '{ firstHiddenTask(trashed: ONLY) { name } }')['data']['firstHiddenTask']).to eq('name' => 'trashed')
        expect(run(schema, '{ firstHiddenTask { name } }')['data']['firstHiddenTask']).to eq('name' => 'kept')
      end

      it 'filters @count' do
        expect(run(schema, '{ hiddenTaskCount }')['data']['hiddenTaskCount']).to eq(1)
        expect(run(schema, '{ hiddenTaskCount(trashed: WITH) }')['data']['hiddenTaskCount']).to eq(2)
        expect(run(schema, '{ hiddenTaskCount(trashed: ONLY) }')['data']['hiddenTaskCount']).to eq(1)
      end
    end

    describe 'on relationships' do
      let(:schema) do
        build_schema(<<~GRAPHQL, dataloader: true)
          #{types}
          type SoftProject {
            id: ID!
            name: String
            softTasks: [SoftTask!]! @hasMany @softDeletes
            paranoidItems: [ParanoidItem!]! @hasMany @softDeletes
            pagedItems: [ParanoidItem!]! @hasMany(relation: "paranoid_items", type: PAGINATOR, defaultCount: 5) @softDeletes
          }
          type Query { projects: [SoftProject!]! @all(model: "SoftProject") }
        GRAPHQL
      end

      before do
        %w[one two].each do |name|
          project = SoftProject.create!(name: name)
          project.soft_tasks.create!(name: "#{name}-task")
          project.soft_tasks.create!(name: "#{name}-old-task", deleted_at: Time.current)
          project.paranoid_items.create!(name: "#{name}-item")
          project.paranoid_items.create!(name: "#{name}-old-item").destroy
        end
      end

      def project_names(result, field)
        result.dig('data', 'projects').map { |project| project[field].map { |row| row['name'] }.sort }
      end

      it 'filters a batched has-many without the argument as before' do
        result = run(schema, '{ projects { softTasks { name } paranoidItems { name } } }')

        expect(project_names(result, 'softTasks')).to eq([%w[one-old-task one-task], %w[two-old-task two-task]])
        expect(project_names(result, 'paranoidItems')).to eq([['one-item'], ['two-item']])
      end

      it 'filters a has-many by trashed, past the default scope of the association' do
        result = run(schema, '{ projects { softTasks(trashed: ONLY) { name } paranoidItems(trashed: ONLY) { name } } }')

        expect(project_names(result, 'softTasks')).to eq([['one-old-task'], ['two-old-task']])
        expect(project_names(result, 'paranoidItems')).to eq([['one-old-item'], ['two-old-item']])
      end

      it 'includes trashed records with WITH, and drops them with WITHOUT' do
        result = run(schema, '{ projects { paranoidItems(trashed: WITH) { name } softTasks(trashed: WITHOUT) { name } } }')

        expect(project_names(result, 'paranoidItems')).to eq([%w[one-item one-old-item], %w[two-item two-old-item]])
        expect(project_names(result, 'softTasks')).to eq([['one-task'], ['two-task']])
      end

      it 'filters a paginated has-many, batched across the parents' do
        result = run(schema, '{ projects { pagedItems(first: 5, trashed: ONLY) { data { name } paginatorInfo { total } } } }')

        pages = result.dig('data', 'projects').pluck('pagedItems')
        expect(pages.map { |page| page['data'].map { |row| row['name'] } }).to eq([['one-old-item'], ['two-old-item']])
        expect(pages.map { |page| page['paginatorInfo']['total'] }).to eq([1, 1])
      end
    end
  end

  describe '@forceDelete and @restore' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        #{types}
        type ProtectedTask { id: ID! name: String }
        type Widget { id: ID! name: String }
        type Query { ok: Boolean }
        type Mutation {
          restoreSoftTask(id: ID! @whereKey): SoftTask @restore
          restoreSoftTasks(ids: [ID!]! @whereKey): [SoftTask!]! @restore
          restoreAlphaTasks(name: String @eq): [SoftTask!]! @restore(model: "SoftTask", scopes: ["alpha"])
          restoreEverything: [SoftTask!]! @restore(model: "SoftTask")
          restoreHiddenTask(id: ID! @whereKey): HiddenTask @restore
          restoreParanoidItem(id: ID! @whereKey): ParanoidItem @restore
          restoreDiscardKeptItem(id: ID! @whereKey): DiscardKeptItem @restore
          restoreWidget(id: ID! @whereKey): Widget @restore
          forceDeleteSoftTask(id: ID! @whereKey): SoftTask @forceDelete
          forceDeleteSoftTasks(ids: [ID!]! @whereKey): [SoftTask!]! @forceDelete
          forceDeleteEverything: [SoftTask!]! @forceDelete(model: "SoftTask")
          forceDeleteParanoidItem(id: ID! @whereKey): ParanoidItem @forceDelete
          forceDeleteDiscardItem(id: ID! @whereKey): DiscardItem @forceDelete
          forceDeleteProtectedTask(id: ID! @whereKey): ProtectedTask @forceDelete
          forceDeleteWidget(id: ID! @whereKey): Widget @forceDelete
        }
      GRAPHQL
    end

    def trash(model, **attributes)
      model.unscoped.create!({ name: 'gone', deleted_at: Time.current }.merge(attributes))
    end

    describe '@restore' do
      it 'restores a trashed model and returns it' do
        task = trash(SoftTask)

        result = run(schema, "mutation { restoreSoftTask(id: #{task.id}) { id name } }")

        expect(result['data']['restoreSoftTask']).to eq('id' => task.id.to_s, 'name' => 'gone')
        expect(task.reload.deleted_at).to be_nil
      end

      it 'restores a list' do
        tasks = Array.new(3) { trash(SoftTask) }
        untouched = trash(SoftTask)

        result = run(schema, "mutation { restoreSoftTasks(ids: [#{tasks.first(2).map(&:id).join(',')}]) { id } }")

        expect(result['data']['restoreSoftTasks'].size).to eq(2)
        expect(SoftTask.where(deleted_at: nil).pluck(:id)).to match_array(tasks.first(2).map(&:id))
        expect(untouched.reload.deleted_at).not_to be_nil
        expect(tasks.last.reload.deleted_at).not_to be_nil
      end

      it 'finds models a default scope hides' do
        task = trash(HiddenTask)

        result = run(schema, "mutation { restoreHiddenTask(id: #{task.id}) { name } }")

        expect(result['data']['restoreHiddenTask']).to eq('name' => 'gone')
        expect(HiddenTask.find(task.id)).to be_present
      end

      it 'restores through paranoia, which hides the model' do
        item = ParanoidItem.create!(name: 'p')
        item.destroy

        result = run(schema, "mutation { restoreParanoidItem(id: #{item.id}) { name } }")

        expect(result['data']['restoreParanoidItem']).to eq('name' => 'p')
        expect(ParanoidItem.find(item.id)).to be_present
      end

      it 'restores through discard, which hides the model with a default scope' do
        item = DiscardKeptItem.create!(name: 'd')
        item.discard

        result = run(schema, "mutation { restoreDiscardKeptItem(id: #{item.id}) { name } }")

        expect(result['data']['restoreDiscardKeptItem']).to eq('name' => 'd')
        expect(DiscardKeptItem.find(item.id)).to be_present
      end

      it 'returns null for a model that does not exist' do
        expect(run(schema, 'mutation { restoreSoftTask(id: 999) { id } }')['data']['restoreSoftTask']).to be_nil
      end

      it 'applies the scopes' do
        alpha = trash(SoftTask, name: 'alpha')
        beta = trash(SoftTask, name: 'beta')

        result = run(schema, 'mutation { restoreAlphaTasks(name: "alpha") { name } }')

        expect(result['data']['restoreAlphaTasks']).to eq([{ 'name' => 'alpha' }])
        expect(alpha.reload.deleted_at).to be_nil
        expect(beta.reload.deleted_at).not_to be_nil
        expect(run(schema, 'mutation { restoreAlphaTasks(name: "beta") { name } }')['data']['restoreAlphaTasks']).to eq([])
      end

      it 'refuses to run without a filter argument' do
        task = trash(SoftTask)

        result = run(schema, 'mutation { restoreEverything { id } }')

        expect(result['errors'].first['message']).to eq('Would modify all models, use an argument to filter.')
        expect(task.reload.deleted_at).not_to be_nil
      end

      it 'fails for a model without soft deletes' do
        widget = Widget.create!(name: 'w')

        result = run(schema, "mutation { restoreWidget(id: #{widget.id}) { id } }")

        expect(result['errors'].first['message']).to include('Model Widget does not support soft deletes')
      end

      it 'also runs without a transaction' do
        Lighthouse::Config.transactional_mutations = false
        task = trash(SoftTask)

        run(schema, "mutation { restoreSoftTask(id: #{task.id}) { id } }")

        expect(task.reload.deleted_at).to be_nil
      end
    end

    describe '@forceDelete' do
      it 'permanently removes a trashed model and returns it' do
        task = trash(SoftTask)

        result = run(schema, "mutation { forceDeleteSoftTask(id: #{task.id}) { id name } }")

        expect(result['data']['forceDeleteSoftTask']).to eq('id' => task.id.to_s, 'name' => 'gone')
        expect(SoftTask.unscoped.where(id: task.id)).not_to exist
      end

      it 'removes a list' do
        tasks = Array.new(3) { trash(SoftTask) }

        result = run(schema, "mutation { forceDeleteSoftTasks(ids: [#{tasks.first(2).map(&:id).join(',')}]) { id } }")

        expect(result['data']['forceDeleteSoftTasks'].size).to eq(2)
        expect(SoftTask.unscoped.pluck(:id)).to eq([tasks.last.id])
      end

      it 'removes a kept model too, as PHP Lighthouse does' do
        task = SoftTask.create!(name: 'kept')

        run(schema, "mutation { forceDeleteSoftTask(id: #{task.id}) { id } }")

        expect(SoftTask.unscoped.where(id: task.id)).not_to exist
      end

      it 'really deletes a paranoia model' do
        item = ParanoidItem.create!(name: 'p')
        item.destroy

        result = run(schema, "mutation { forceDeleteParanoidItem(id: #{item.id}) { name } }")

        expect(result['data']['forceDeleteParanoidItem']).to eq('name' => 'p')
        expect(ParanoidItem.with_deleted.where(id: item.id)).not_to exist
      end

      it 'really deletes a discard model' do
        item = DiscardItem.create!(name: 'd')
        item.discard

        run(schema, "mutation { forceDeleteDiscardItem(id: #{item.id}) { name } }")

        expect(DiscardItem.where(id: item.id)).not_to exist
      end

      it 'reports a model whose callbacks refuse' do
        task = ProtectedTask.create!(name: 'keep me', deleted_at: Time.current)

        result = run(schema, "mutation { forceDeleteProtectedTask(id: #{task.id}) { id } }")

        expect(result['errors'].first['message']).to eq("Could not modify model ProtectedTask with ID #{task.id}.")
        expect(SoftTask.unscoped.where(id: task.id)).to exist
      end

      it 'refuses to run without a filter argument' do
        task = trash(SoftTask)

        result = run(schema, 'mutation { forceDeleteEverything { id } }')

        expect(result['errors'].first['message']).to eq('Would modify all models, use an argument to filter.')
        expect(SoftTask.unscoped.where(id: task.id)).to exist
      end

      it 'fails for a model without soft deletes' do
        widget = Widget.create!(name: 'w')

        result = run(schema, "mutation { forceDeleteWidget(id: #{widget.id}) { id } }")

        expect(result['errors'].first['message']).to include('Model Widget does not support soft deletes')
        expect(Widget.where(id: widget.id)).to exist
      end
    end

    it 'does not touch @delete, which still destroys through the model' do
      schema = build_schema(<<~GRAPHQL)
        type Widget { id: ID! name: String }
        type Query { ok: Boolean }
        type Mutation { deleteWidget(id: ID! @whereKey): Widget @delete }
      GRAPHQL
      widget = Widget.create!(name: 'w')

      expect(run(schema, "mutation { deleteWidget(id: #{widget.id}) { name } }")['data']['deleteWidget']).to eq('name' => 'w')
      expect(Widget.where(id: widget.id)).not_to exist
    end
  end

  describe 'Config.soft_deletes' do
    let(:adapter) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def soft_deletes?(model) = model == Widget

        def only_trashed(relation) = record(:only, relation.where(name: 'trashed'))
        def with_trashed(relation) = record(:with, relation)
        def without_trashed(relation) = record(:without, relation.where.not(name: 'trashed'))

        def restore(record)
          @calls << :restore
          record.update_columns(name: 'restored') # rubocop:disable Rails/SkipsModelValidations
        end

        def force_delete(record)
          @calls << :force_delete
          record.destroy
        end

        private

        def record(kind, relation)
          @calls << kind
          relation
        end
      end.new
    end
    let(:schema) do
      build_schema(<<~GRAPHQL)
        type Widget { id: ID! name: String }
        type Post { id: ID! }
        type Query { widgets: [Widget!]! @all @softDeletes posts: [Post!]! @all @softDeletes }
        type Mutation {
          restoreWidget(id: ID! @whereKey): Widget @restore
          forceDeleteWidget(id: ID! @whereKey): Widget @forceDelete
        }
      GRAPHQL
    end

    before do
      Lighthouse::Config.soft_deletes = adapter
      Widget.create!(name: 'trashed')
      Widget.create!(name: 'kept')
    end

    it 'replaces the detection' do
      expect(names(run(schema, '{ widgets(trashed: ONLY) { name } }'), 'widgets')).to eq(['trashed'])
      expect(names(run(schema, '{ widgets(trashed: WITHOUT) { name } }'), 'widgets')).to eq(['kept'])
      expect(names(run(schema, '{ widgets(trashed: WITH) { name } }'), 'widgets')).to contain_exactly('trashed', 'kept')
      expect(adapter.calls).to eq(%i[only without with])
      expect(run(schema, '{ posts(trashed: ONLY) { id } }')['errors'].first['message']).to include('Model Post does not support soft deletes')
    end

    it 'restores and force deletes through the adapter' do
      id = Widget.find_by!(name: 'kept').id

      run(schema, "mutation { restoreWidget(id: #{id}) { id } }")
      expect(Widget.find(id).name).to eq('restored')

      run(schema, "mutation { forceDeleteWidget(id: #{id}) { id } }")
      expect(Widget.where(id: id)).not_to exist
      expect(adapter.calls).to eq(%i[with restore with force_delete])
    end
  end

  describe Lighthouse::Support::SoftDeletes do
    it 'detects the strategy of each model' do
      auto = described_class::Auto.new

      expect([SoftTask, HiddenTask, ParanoidItem, DiscardItem, DiscardKeptItem].map { |model| auto.soft_deletes?(model) }).to all(be(true))
      expect([Widget, Post, ScheduledPost].map { |model| auto.soft_deletes?(model) }).to all(be(false))
      expect(described_class::Paranoia.new.soft_deletes?(ParanoidItem)).to be(true)
      expect(described_class::Paranoia.new.soft_deletes?(SoftTask)).to be(false)
      expect(described_class::Discard.new.soft_deletes?(DiscardItem)).to be(true)
      expect(described_class::Discard.new.soft_deletes?(ParanoidItem)).to be(false)
    end

    it 'takes another column' do
      column = described_class::Column.new(:schedule_at)

      expect(column.soft_deletes?(ScheduledPost)).to be(true)
      expect(column.soft_deletes?(SoftTask)).to be(false)
      expect(column.only_trashed(ScheduledPost.all).to_sql).to include('"scheduled_posts"."schedule_at" IS NOT NULL')
    end

    it 'prefers the gem over the column of the same name' do
      expect(described_class::Auto.new.send(:strategy, ParanoidItem)).to be_a(described_class::Paranoia)
    end
  end
end
