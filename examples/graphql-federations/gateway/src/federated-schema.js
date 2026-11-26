import { getStitchedSchemaFromSupergraphSdl } from '@graphql-tools/federation';

import * as InterfaceObjects from './interface-objects.js';

// The gateway's schema: the supergraph stitched by @graphql-tools/federation,
// with @interfaceObject (interface-objects.js). Each subgraph is reached through
// @graphql-tools/executor-http: queries and mutations as POSTs, subscriptions as
// a GET that asks for `text/event-stream`, which Lighthouse answers over
// Server-Sent Events (Lighthouse::GraphQL::EventStream).
//
// `endpoints`: a subgraph's URL by its name, instead of the supergraph's.
// `forward`: the headers of the client's request passed on to every subgraph.
export function federatedSchema(supergraphSdl, { endpoints = {}, forward = ['authorization'] } = {}) {
  const interfaceObjects = InterfaceObjects.collect(supergraphSdl);
  const graphNames = InterfaceObjects.subgraphNamesOf(supergraphSdl);
  const nameOf = (graph) => graphNames.get(graph) ?? graph;
  const mappingsFor = (subgraph) =>
    interfaceObjects.filter((mapping) => mapping.graph === subgraph || nameOf(mapping.graph) === subgraph);

  return getStitchedSchemaFromSupergraphSdl({
    supergraphSdl: InterfaceObjects.apply(supergraphSdl, interfaceObjects),
    batch: true,
    httpExecutorOpts: ({ name, endpoint }) => ({
      endpoint: endpoints[nameOf(name)] ?? endpoint,
      headers: (request) => forwarded(request?.context?.request, forward),
    }),
    onSubgraphAST: (subgraph, ast) =>
      mappingsFor(subgraph).reduce((document, mapping) => InterfaceObjects.implementationTypeDefs(document, mapping), ast),
    onSubschemaConfig: (subschemaConfig) => {
      const mappings = mappingsFor(subschemaConfig.name ?? '');
      if (!mappings.length) return;

      for (const mapping of mappings) {
        for (const implementation of mapping.implementations) {
          const merged = subschemaConfig.merge?.[implementation];
          if (merged) merged.key = InterfaceObjects.keyFn(mapping, merged.key);
        }
      }
      const inner = subschemaConfig.executor;
      subschemaConfig.executor = (request) =>
        inner({ ...request, document: InterfaceObjects.rewriteTypeConditions(request.document, mappings) });
    },
  });
}

function forwarded(request, names) {
  const headers = {};
  for (const name of names) {
    const value = request?.headers?.get(name);
    if (value) headers[name] = value;
  }
  return headers;
}
