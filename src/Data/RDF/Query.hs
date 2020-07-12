{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Data.RDF.Query
  ( -- * Query functions
    equalSubjects,
    equalPredicates,
    equalObjects,
    subjectOf,
    predicateOf,
    objectOf,
    isEmpty,
--    rdfContainsNode,
--    tripleContainsNode,
    subjectsWithPredicate,
    objectsOfPredicate,
    uordered,

    -- * RDF graph functions
    isIsomorphic,
    isGraphIsomorphic,
    expandTriples,
    fromEither,

    -- * expansion functions
    expandTriple,
    expandNode,
    expandURI,

    -- * absolutizing functions
    absolutizeTriple,
    absolutizeNode,
    absolutizeNodeUnsafe,
    QueryException(..)
  )
where

import Control.Applicative ((<|>))
import Control.Exception
import Data.Graph (Graph, graphFromEdges)
import qualified Data.Graph.Automorphism as Automorphism
import qualified Data.HashMap.Strict as HashMap
import Data.HashMap.Strict (HashMap)
import Data.List
import Data.Maybe (fromMaybe)
import Data.RDF.IRI
import qualified Data.RDF.Namespace as NS
import Data.RDF.Types
#if MIN_VERSION_base(4,9,0)
#if !MIN_VERSION_base(4,11,0)
import Data.Semigroup
#else
#endif
#else
#endif
import Data.Text (Text)
import qualified Data.Text as T
import Prelude hiding (pred)

-- | Answer the subject node of the triple.
{-# INLINE subjectOf #-}
subjectOf :: Triple -> Subject
subjectOf (Triple s _ _) = s

-- | Answer the predicate node of the triple.
{-# INLINE predicateOf #-}
predicateOf :: Triple -> Predicate
predicateOf (Triple _ p _) = p

-- | Answer the object node of the triple.
{-# INLINE objectOf #-}
objectOf :: Triple -> Object
objectOf (Triple _ _ o) = o

-- | Answer if rdf contains node.
-- rdfContainsNode :: (Rdf a) => RDF a -> Node -> Bool
-- rdfContainsNode rdf node = any (tripleContainsNode node) (triplesOf rdf)

-- | Answer if triple contains node.
--  Note that it doesn't perform namespace expansion!
-- tripleContainsNode :: Node -> Triple -> Bool
-- {-# INLINE tripleContainsNode #-}
-- tripleContainsNode node (Triple s p o) = s == node || p == node || o == node

-- | Determine whether two triples have equal subjects.
--  Note that it doesn't perform namespace expansion!
equalSubjects :: Triple -> Triple -> Bool
equalSubjects (Triple s1 _ _) (Triple s2 _ _) = s1 == s2

-- | Determine whether two triples have equal predicates.
--  Note that it doesn't perform namespace expansion!
equalPredicates :: Triple -> Triple -> Bool
equalPredicates (Triple _ p1 _) (Triple _ p2 _) = p1 == p2

-- | Determine whether two triples have equal objects.
--  Note that it doesn't perform namespace expansion!
equalObjects :: Triple -> Triple -> Bool
equalObjects (Triple _ _ o1) (Triple _ _ o2) = o1 == o2

-- | Determines whether the 'RDF' contains zero triples.
isEmpty :: Rdf a => RDF a -> Bool
isEmpty = null . triplesOf

-- | Lists of all subjects of triples with the given predicate.
subjectsWithPredicate :: Rdf a => RDF a -> Predicate -> [Subject]
subjectsWithPredicate rdf pred = subjectOf <$> query rdf Nothing (Just pred) Nothing

-- | Lists of all objects of triples with the given predicate.
objectsOfPredicate :: Rdf a => RDF a -> Predicate -> [Object]
objectsOfPredicate rdf pred = objectOf <$> query rdf Nothing (Just pred) Nothing

-- | Convert a parse result into an RDF if it was successful
--  and error and terminate if not.
fromEither :: Either ParseFailure (RDF a) -> RDF a
fromEither (Left err) = error (show err)
fromEither (Right rdf) = rdf

-- | Convert a list of triples into a sorted list of unique triples.
uordered :: Triples -> Triples
uordered = sort . nub

-- graphFromEdges :: Ord key => [(node, key, [key])] -> (Graph, Vertex -> (node, key, [key]), key -> Maybe Vertex)

-- | This determines if two RDF representations are equal regardless
--  of blank node names, triple order and prefixes. In math terms,
--  this is the \simeq latex operator, or ~= . Unsafe because it
--  assumes IRI resolution will succeed, may throw an
--  'IRIResolutionException` exception.
isIsomorphic :: (Rdf a, Rdf b) => RDF a -> RDF b -> Bool
isIsomorphic g1 g2 = and $ zipWith compareTripleUnlessBlank (normalize g1) (normalize g2)
  where
    compareSubjectUnlessBlank :: Subject -> Subject -> Bool
    compareSubjectUnlessBlank BlankSubject BlankSubject = True
    compareSubjectUnlessBlank s1 s2 = s1 == s2
    compareObjectUnlessBlank :: Object -> Object -> Bool
    compareObjectUnlessBlank BlankObject BlankObject = True
    compareObjectUnlessBlank o1 o2 = o1 == o2
    -- compareNodeUnlessBlank :: Node -> Node -> Bool
    -- compareNodeUnlessBlank (BNode _) (BNode _) = True
    -- compareNodeUnlessBlank (UNode n1) (UNode n2) = n1 == n2
    -- compareNodeUnlessBlank (BNodeGen i1) (BNodeGen i2) = i1 == i2
    -- compareNodeUnlessBlank (LNode l1) (LNode l2) = l1 == l2
    -- compareNodeUnlessBlank (BNodeGen _) (BNode _) = True
    -- compareNodeUnlessBlank (BNode _) (BNodeGen _) = True
    -- compareNodeUnlessBlank _ _ = False
    compareTripleUnlessBlank :: Triple -> Triple -> Bool
    compareTripleUnlessBlank (Triple s1 p1 o1) (Triple s2 p2 o2) =
      compareSubjectUnlessBlank s1 s2
        && p1 == p2
        && compareObjectUnlessBlank o1 o2
    normalize :: (Rdf a) => RDF a -> Triples
    normalize = sort . nub . expandTriples

-- | Compares the structure of two graphs and returns 'True' if their
--   graph structures are identical. This does not consider the nature
--   of each node in the graph, i.e. the URI text of 'UNode' nodes,
--   the generated index of a blank node, or the values in literal
--   nodes. Unsafe because it assumes IRI resolution will succeed, may
--   throw an 'IRIResolutionException` exception.
isGraphIsomorphic :: (Rdf a, Rdf b) => RDF a -> RDF b -> Bool
isGraphIsomorphic g1 g2 = Automorphism.isIsomorphic g1' g2'
  where
    g1' = rdfGraphToDataGraph g1
    g2' = rdfGraphToDataGraph g2
    rdfGraphToDataGraph :: Rdf c => RDF c -> Graph
    rdfGraphToDataGraph g = dataGraph
      where
        triples = expandTriples g
        triplesHashMap :: HashMap (Subject, Predicate) [Object]
        triplesHashMap = HashMap.fromListWith (<>) [((s, p), [o]) | Triple s p o <- triples]
        triplesGrouped :: [((Subject, Predicate), [Object])]
        triplesGrouped = HashMap.toList triplesHashMap
        (dataGraph, _, _) = (graphFromEdges . fmap (\((s, p), os) -> (s, p, os))) triplesGrouped

class ExpandableURI e where
  expandUri :: PrefixMappings -> e -> e

instance ExpandableURI Subject where
  expandUri pms (UriSubject (pf :* path)) = UriSubject . UriNode $ expandURI pms (pf <> ":" <> path)
  expandUri _ s = s

instance ExpandableURI Predicate where
  expandUri pms (Predicate (pf :* path)) = Predicate . UriNode $ expandURI pms (pf <> ":" <> path)
  expandUri _ p = p

instance ExpandableURI Object where
  expandUri pms (ObjectUri (pf :* path)) = ObjectUri . UriNode $ expandURI pms (pf <> ":" <> path)
  expandUri _ o = o

-- | Expand the triples in a graph with the prefix map and base URL
-- for that graph. Unsafe because it assumes IRI resolution will
-- succeed, may throw an 'IRIResolutionException` exception.
expandTriples :: (Rdf a) => RDF a -> Triples
expandTriples rdf = normalize <$> triplesOf rdf
  where
    normalize = absolutizeTriple (baseUrl rdf) . expandTriple (prefixMappings rdf)

-- | Expand the triple with the prefix map.
expandTriple :: PrefixMappings -> Triple -> Triple
expandTriple pms (Triple s p o) = triple (expandSubjectURI pms s) (expandPredicateURI pms p) (expandObjectURI pms o)

-- nodeToURINode :: Node -> Maybe UriNode
-- nodeToURINode (SubjectNode (UriSubject u)) = Just u
-- nodeToURINode (Predicate u) = Just u
-- nodeToURINode (ObjectUri u) = Just u
-- nodeToURINode _ = Nothing

-- | Expand the node with the prefix map.
--  Only UNodes are expanded, other kinds of nodes are returned as-is.
-- expandNode :: PrefixMappings -> Node -> Node
-- expandNode pms (UNode u) = unode $ expandURI pms u
-- expandNode _ n = n

-- | Expand the URI with the prefix map.
--  Also expands "a" to "http://www.w3.org/1999/02/22-rdf-syntax-ns#type".
expandURI :: PrefixMappings -> Text -> Text
expandURI _ "a" = NS.mkUri NS.rdf "type"
expandURI pms iri = fromMaybe iri $ foldl' f Nothing (NS.toPMList pms)
  where
    f :: Maybe Text -> (Text, Text) -> Maybe Text
    f x (p, u) = x <|> (T.append u <$> T.stripPrefix (T.append p ":") iri)

expandSubjectURI :: PrefixMappings -> Subject -> Subject
expandSubjectURI pms (UriSubject (UriNode uri)) = UriSubject $ UriNode (expandURI pms uri)
expandSubjectURI _ s = s

expandPredicateURI :: PrefixMappings -> Predicate -> Predicate
expandPredicateURI pms (Predicate (UriNode uri)) = Predicate $ UriNode (expandURI pms uri)

expandObjectURI :: PrefixMappings -> Object -> Object
expandObjectURI pms (ObjectUri (UriNode uri)) = ObjectUri $ UriNode (expandURI pms uri)
expandObjectURI _ o = o

-- | Prefixes relative URIs in the triple with BaseUrl. Unsafe because
-- it assumes IRI resolution will succeed, may throw an
-- 'IRIResolutionException` exception.
absolutizeTriple :: Maybe BaseUrl -> Triple -> Triple
absolutizeTriple base (Triple s p o) = triple (absolutizeNodeUnsafe base s) (absolutizeNodeUnsafe base p) (absolutizeNodeUnsafe base o)

-- | Prepends BaseUrl to UNodes with relative URIs.
-- absolutizeNode :: Maybe BaseUrl -> Node -> Either String Node
-- absolutizeNode (Just (BaseUrl b)) (UNode u) =
--   case resolveIRI b u of
--     Left iriErr -> Left iriErr
--     Right t -> Right (unode t)
-- absolutizeNode _ n = Right n

data QueryException
  = IRIResolutionException String
  deriving (Show)

instance Exception QueryException

-- | Prepends BaseUrl to UNodes with relative URIs. Unsafe because it
-- assumes IRI resolution will succeed, may throw an
-- 'IRIResolutionException` exception.
absolutizeNodeUnsafe :: Maybe BaseUrl -> UriNode -> UriNode
absolutizeNodeUnsafe (Just (BaseUrl b)) (UriNode u) =
  case resolveIRI b u of
    Left iriErr -> throw (IRIResolutionException iriErr)
    Right t -> UriNode t
absolutizeNodeUnsafe _ n = n
