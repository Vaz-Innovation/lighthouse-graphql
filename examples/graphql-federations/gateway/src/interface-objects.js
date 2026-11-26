import { Kind, parse, print, visit } from 'graphql';

// @interfaceObject for @graphql-tools/federation, which stitches the supergraph
// without it: a subgraph (accounts) that adds fields to an entity interface it
// knows as an object type (Authored, which the blog owns, with Post and Comment).
//
// From the supergraph's `@join__type(graph:, key:, isInterfaceObject: true)`:
//
// - `apply` joins every implementation (Post, Comment) to that subgraph, on the
//   interface's key, and its fields (likesCount, likedBy) to it, so the stitched
//   schema plans them there;
// - `implementationTypeDefs` gives the subgraph's own schema an object type per
//   implementation, copied from its `Authored`, for the planner to delegate to;
// - `rewriteTypeConditions` turns the implementations back into `Authored` in
//   the documents sent to that subgraph (`_entities` representations, fragments),
//   since it knows no Post nor Comment;
// - `keyFn` makes each representation sent to it an `Authored` one.
//
// Ported from a NestJS gateway on GraphQL Yoga.

/**
 * @typedef {object} InterfaceObjectMapping
 * @property {string} interfaceName the entity interface (Authored)
 * @property {string} graph the join__Graph value of the subgraph that has it as an object (ACCOUNTS)
 * @property {string} key the interface's key in that subgraph
 * @property {string[]} fields the fields that subgraph adds
 * @property {string[]} implementations the interface's object types
 * @property {Map<string, string>} requiresByField the `@requires` of each of those fields
 */

/** The @interfaceObject of a supergraph: one mapping per interface and subgraph. */
export function collect(supergraphSdl) {
  const document = typeof supergraphSdl === 'string' ? parse(supergraphSdl, { noLocation: true }) : supergraphSdl;

  return document.definitions.flatMap((definition) =>
    definition.kind === Kind.INTERFACE_TYPE_DEFINITION
      ? interfaceObjectJoins(definition)
          .map((join) => mappingOf(document, definition, join))
          .filter(Boolean)
      : [],
  );
}

function mappingOf(document, definition, join) {
  const graph = argOf(join, 'graph');
  const key = argOf(join, 'key');
  if (!graph || !key) return undefined;

  const joinIn = (field) =>
    directives(field).find((directive) => directive.name.value === 'join__field' && argOf(directive, 'graph') === graph);
  const fields = (definition.fields ?? []).filter(joinIn).map((field) => field.name.value);
  if (!fields.length) return undefined;

  const implementations = document.definitions
    .filter(
      (candidate) =>
        candidate.kind === Kind.OBJECT_TYPE_DEFINITION &&
        (candidate.interfaces ?? []).some((named) => named.name.value === definition.name.value),
    )
    .map((candidate) => candidate.name.value);
  if (!implementations.length) return undefined;

  const requiresByField = new Map();
  for (const field of definition.fields ?? []) {
    const requires = fields.includes(field.name.value) && argOf(joinIn(field), 'requires');
    if (requires) requiresByField.set(field.name.value, requires);
  }

  return { interfaceName: definition.name.value, graph, key, fields, implementations, requiresByField };
}

/** The supergraph, with each implementation joined to the subgraphs that extend its interface. */
export function apply(supergraphSdl, mappings) {
  return mappings.reduce((sdl, mapping) => applyOne(sdl, mapping), supergraphSdl);
}

function applyOne(supergraphSdl, mapping) {
  const document = parse(supergraphSdl, { noLocation: true });

  const definitions = document.definitions.map((definition) => {
    if (definition.kind !== Kind.OBJECT_TYPE_DEFINITION || !mapping.implementations.includes(definition.name.value)) {
      return definition;
    }

    const typeJoins = directives(definition).filter((directive) => directive.name.value === 'join__type');
    const alreadyJoined = typeJoins.some((directive) => argOf(directive, 'graph') === mapping.graph);
    const extraDirectives = alreadyJoined
      ? []
      : parse(`type _X @join__type(graph: ${mapping.graph}, key: "${mapping.key}") { _x: ID }`, { noLocation: true })
          .definitions[0].directives;
    const originalGraphs = typeJoins.map((directive) => argOf(directive, 'graph')).filter(Boolean);

    const fields = (definition.fields ?? []).map((field) => {
      const joins = directives(field).filter((directive) => directive.name.value === 'join__field');

      if (mapping.fields.includes(field.name.value)) {
        return {
          ...field,
          directives: directives(field).map((directive) =>
            directive.name.value === 'join__field' && !argOf(directive, 'graph')
              ? joinFieldFor(mapping.graph, mapping.requiresByField.get(field.name.value))
              : directive,
          ),
        };
      }

      // A field of the implementation's own subgraphs, now that it has another.
      if (joins.length || alreadyJoined) return field;

      return { ...field, directives: [...directives(field), ...originalGraphs.map((graph) => joinFieldFor(graph))] };
    });

    return { ...definition, directives: [...directives(definition), ...extraDirectives], fields };
  });

  return print({ ...document, definitions });
}

/** A subgraph's schema, with an object type per implementation, as its interface object. */
export function implementationTypeDefs(subgraphAst, mapping) {
  const source = subgraphAst.definitions.find(
    (definition) => definition.kind === Kind.OBJECT_TYPE_DEFINITION && definition.name.value === mapping.interfaceName,
  );
  if (!source) return subgraphAst;

  const existing = new Set(
    subgraphAst.definitions
      .filter((definition) => definition.kind === Kind.OBJECT_TYPE_DEFINITION)
      .map((definition) => definition.name.value),
  );
  const added = mapping.implementations
    .filter((implementation) => !existing.has(implementation))
    .map((implementation) => ({ ...source, name: { kind: Kind.NAME, value: implementation } }));

  return added.length ? { ...subgraphAst, definitions: [...subgraphAst.definitions, ...added] } : subgraphAst;
}

/** A document for the subgraph, with each implementation named as its interface. */
export function rewriteTypeConditions(document, mappings) {
  const interfaceOf = new Map();
  for (const mapping of mappings) {
    for (const implementation of mapping.implementations) interfaceOf.set(implementation, mapping.interfaceName);
  }
  if (!interfaceOf.size) return document;

  let rewrote = false;
  const rewritten = visit(document, {
    NamedType(node) {
      const interfaceName = interfaceOf.get(node.name.value);
      if (!interfaceName) return undefined;

      rewrote = true;
      return { ...node, name: { kind: Kind.NAME, value: interfaceName } };
    },
  });
  return rewrote ? rewritten : document;
}

/** The representation of an implementation's record for the subgraph: its interface's. */
export function keyFn(mapping, derived) {
  const keyProps = mapping.key
    .trim()
    .split(/\s+/)
    .filter((prop) => prop && prop !== '__typename');

  return function interfaceObjectKey(root) {
    if (root == null) return null;

    if (derived) {
      const representation = derived(root);
      return representation == null ? representation : { ...representation, __typename: mapping.interfaceName };
    }

    const representation = { __typename: mapping.interfaceName };
    for (const prop of keyProps) {
      if (root[prop] == null) return null;
      representation[prop] = root[prop];
    }
    return representation;
  };
}

/** join__Graph value → subgraph name (ACCOUNTS → accounts), from the supergraph's `@join__graph`. */
export function subgraphNamesOf(supergraphSdl) {
  const names = new Map();
  for (const definition of parse(supergraphSdl, { noLocation: true }).definitions) {
    if (definition.kind !== Kind.ENUM_TYPE_DEFINITION || definition.name.value !== 'join__Graph') continue;

    for (const value of definition.values ?? []) {
      const graph = directives(value).find((directive) => directive.name.value === 'join__graph');
      const name = graph && argOf(graph, 'name');
      if (name) names.set(value.name.value, name);
    }
  }
  return names;
}

const directives = (node) => node?.directives ?? [];

function argOf(directive, name) {
  const arg = directive?.arguments?.find((candidate) => candidate.name.value === name);
  if (!arg) return undefined;
  if (arg.value.kind === Kind.STRING || arg.value.kind === Kind.ENUM) return arg.value.value;
  if (arg.value.kind === Kind.BOOLEAN) return String(arg.value.value);
  return undefined;
}

const interfaceObjectJoins = (node) =>
  directives(node).filter((directive) => directive.name.value === 'join__type' && argOf(directive, 'isInterfaceObject') === 'true');

function joinFieldFor(graph, requires) {
  const args = requires ? `graph: ${graph}, requires: ${JSON.stringify(requires)}` : `graph: ${graph}`;
  return parse(`type _X { _x: ID @join__field(${args}) }`, { noLocation: true }).definitions[0].fields[0].directives[0];
}
