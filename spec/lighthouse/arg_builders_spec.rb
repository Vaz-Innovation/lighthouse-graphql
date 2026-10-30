# frozen_string_literal: true

RSpec.describe 'Argument builder directives' do
  # Minimal AST stand-ins: an argument node exposes `#name`; a directive node
  # exposes `#arguments` (each with `#name` and `#value`).
  before do
    stub_const('ArgNode', Struct.new(:name))
    stub_const('DirArg', Struct.new(:name, :value))
    stub_const('DirNode', Struct.new(:name, :arguments))
  end

  def arg(name) = ArgNode.new(name)
  def directive(opts = {}) = DirNode.new('eq', opts.map { |k, v| DirArg.new(k.to_s, v) })

  let(:relation) { Widget.all }
  let(:mod) { Lighthouse::GraphQL::Directives::Arguments }

  describe 'Eq' do
    it 'adds an equality WHERE on the snake_cased argument name' do
      sql = mod::Eq.new(arg('email'), directive).handle_builder(relation, 'a@b.com').to_sql
      expect(sql).to match(/"email"\s*=/)
    end

    it 'is a no-op when value is nil' do
      expect(mod::Eq.new(arg('email'), directive).handle_builder(relation, nil)).to eq(relation)
    end

    it 'honors the key: override' do
      sql = mod::Eq.new(arg('whatever'), directive(key: 'name')).handle_builder(relation, 'x').to_sql
      expect(sql).to match(/"name"\s*=/)
    end
  end

  describe 'Neq' do
    it 'adds a negated WHERE' do
      sql = mod::Neq.new(arg('email'), directive).handle_builder(relation, 'x').to_sql
      expect(sql).to match(/"email"\s*(!=|<>)/)
    end
  end

  describe 'In' do
    it 'adds an IN clause from a list' do
      sql = mod::In.new(arg('email'), directive).handle_builder(relation, %w[a b]).to_sql
      expect(sql).to include('"email" IN')
    end
  end

  describe 'NotIn' do
    it 'adds a NOT IN clause' do
      sql = mod::NotIn.new(arg('email'), directive).handle_builder(relation, %w[a b]).to_sql
      expect(sql).to include('"email" NOT IN')
    end
  end

  describe 'Like' do
    it 'adds a LIKE clause wrapped in wildcards' do
      sql = mod::Like.new(arg('name'), directive).handle_builder(relation, 'foo').to_sql
      expect(sql).to include('LIKE')
      expect(sql).to include('%foo%')
    end
  end

  describe 'Where' do
    it 'applies the operator via the SQLOperator map (GT)' do
      sql = mod::Where.new(arg('rank'), directive(operator: 'GT')).handle_builder(relation, 5).to_sql
      expect(sql).to match(/"rank"\s*>/)
    end

    it 'defaults to equality when no operator is given' do
      sql = mod::Where.new(arg('email'), directive).handle_builder(relation, 'x').to_sql
      expect(sql).to match(/"email"\s*=/)
    end

    it 'supports IS_NULL' do
      sql = mod::Where.new(arg('email'), directive(operator: 'IS_NULL')).handle_builder(relation, true).to_sql
      expect(sql).to include('"email" IS NULL')
    end
  end

  describe 'OrderBy' do
    it 'orders by a single clause, mapping the enum column and direction' do
      sql = mod::OrderBy.new(arg('orderBy'), directive)
                        .handle_builder(relation, [{ 'column' => 'NAME', 'order' => 'DESC' }]).to_sql
      expect(sql).to match(/ORDER BY "widgets"."name" DESC/)
    end

    it 'preserves multi-column order' do
      sql = mod::OrderBy.new(arg('orderBy'), directive)
                        .handle_builder(relation, [
                                          { 'column' => 'NAME', 'order' => 'ASC' },
                                          { 'column' => 'EMAIL', 'order' => 'DESC' }
                                        ]).to_sql
      expect(sql).to match(/ORDER BY "widgets"."name" ASC, "widgets"."email" DESC/)
    end
  end
end
