import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';

import { createYoga } from 'graphql-yoga';

import { federatedSchema } from './federated-schema.js';

// GraphQL Yoga in front of the subgraphs, on PORT (4100). Clients query it at
// /graphql, and subscribe over Server-Sent Events (graphql-sse, which Yoga
// speaks); it asks the subgraphs for subscriptions over SSE in turn.
//
//   SUPERGRAPH=../router/supergraph.graphql        the composed supergraph (bin/compose)
//   SUBGRAPH_URLS='{"accounts":"http://localhost:3001/graphql"}'   instead of its routing URLs
const supergraph = process.env.SUPERGRAPH ?? new URL('../../router/supergraph.graphql', import.meta.url);
const endpoints = JSON.parse(process.env.SUBGRAPH_URLS ?? '{}');
const port = Number(process.env.PORT ?? 4100);

const yoga = createYoga({
  schema: federatedSchema(readFileSync(supergraph, 'utf8'), { endpoints }),
  graphqlEndpoint: '/graphql',
  landingPage: false,
  // The suite reads the subgraphs' errors as they answer them.
  maskedErrors: false,
});

createServer(yoga).listen(port, '127.0.0.1', () => {
  console.log(`Gateway on http://127.0.0.1:${port}/graphql`);
});
