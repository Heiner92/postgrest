{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
module PostgREST.App where
-- module PostgREST.App (
--   app
-- , sqlError
-- , isSqlError
-- , contentTypeForAccept
-- , jsonH
-- , TableOptions(..)
-- , parsePostRequest
-- , rr
-- , bb
-- ) where

import qualified Blaze.ByteString.Builder  as BB
import           Control.Applicative
import           Control.Arrow             ((***))
import           Control.Monad             (join)
import           Data.Bifunctor            (first)
import qualified Data.ByteString.Char8     as BS
import qualified Data.ByteString.Lazy      as BL
import           Data.CaseInsensitive      (original)
import qualified Data.Csv                  as CSV
import           Data.Functor.Identity
import qualified Data.HashMap.Strict       as M
import           Data.List                 (find, sortBy, delete, transpose)
import           Data.Maybe                (fromMaybe, fromJust, isJust, isNothing)
import           Data.Ord                  (comparing)
import           Data.Ranged.Ranges        (emptyRange)
import qualified Data.Set                  as S
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text, replace, strip)
import           Data.Tree
--import           Data.Foldable             (forlrM)

import           Text.Parsec.Error
import           Text.ParserCombinators.Parsec (parse)

import           Network.HTTP.Base         (urlEncodeVars)
import           Network.HTTP.Types.Header
import           Network.HTTP.Types.Status
import           Network.HTTP.Types.URI    (parseSimpleQuery)
import           Network.Wai
--import           Network.Wai.Internal
import           Network.Wai.Internal      (Response (..))
import           Network.Wai.Parse         (parseHttpAccept)

import           Data.Aeson
import           Data.Monoid
import qualified Data.Vector               as V
import qualified Hasql                     as H
import qualified Hasql.Backend             as B
import qualified Hasql.Postgres            as P

import           PostgREST.Auth
import           PostgREST.Config          (AppConfig (..))
import           PostgREST.Parsers
import           PostgREST.PgQuery
import           PostgREST.PgStructure
import           PostgREST.QueryBuilder
import           PostgREST.RangeQuery
import           PostgREST.Types

import           Prelude

app :: DbStructure -> AppConfig -> DbRole -> BL.ByteString -> DbRole -> Request -> H.Tx P.Postgres s Response
app dbstructure conf authenticator reqBody dbrole req =
  case (path, verb) of

    ([], _) -> do
      let body = encode $ filter (filterTableAcl dbrole) $ filter ((cs schema==).tableSchema) allTabs
      return $ responseLBS status200 [jsonH] $ cs body

    ([table], "OPTIONS") -> do
      let cols = filter (filterCol schema table) allCols
          pkeys = map pkName $ filter (filterPk schema table) allPrKeys
          body = encode (TableOptions cols pkeys)
      return $ responseLBS status200 [jsonH, allOrigins] $ cs body

    ([table], "GET") ->
      if range == Just emptyRange
      then return $ responseLBS status416 [] "HTTP Range error"
      else
        case query of
          Left e -> return $ responseLBS status400 [("Content-Type", "application/json")] $ cs e
          Right qs -> do
            -- let qt = qualify table
            --     count = if hasPrefer "count=none"
            --           then countNone
            --           else cqs
            --     q = B.Stmt "select " V.empty True <>
            --         parentheticT count
            --         <> commaq <> (
            --         bodyForAccept contentType qt -- TODO! when in csv mode, the first row (columns) is not correct when requesting sub tables
            --         . limitT range
            --         $ qs
            --       )

            let q = B.Stmt
                    (withSourceF qs <>
                    " SELECT " <>
                      (if hasPrefer "count=none" then countNoneF else countAllF) <>
                      "," <>
                      countF <>
                      "," <>
                      (case contentType of
                        "text/csv" -> asCsvF
                        _     -> asJsonF
                      ) <>
                    " " <>
                    fromF ( limitF range ))
                    V.empty True
            row <- H.maybeEx q
            let (tableTotal, queryTotal, body) = fromMaybe (Just (0::Int), 0::Int, Just "" :: Maybe BL.ByteString) row
                to = frm+queryTotal-1
                contentRange = contentRangeH frm to tableTotal
                status = rangeStatus frm to tableTotal
                canonical = urlEncodeVars
                  . sortBy (comparing fst)
                  . map (join (***) cs)
                  . parseSimpleQuery
                  $ rawQueryString req
            return $ responseLBS status
              [contentTypeH, contentRange,
                ("Content-Location",
                  "/" <> cs table <>
                    if Prelude.null canonical then "" else "?" <> cs canonical
                )
              ] (fromMaybe "[]" body)

        where
            frm = fromMaybe 0 $ rangeOffset <$> range
            apiRequest = first formatParserError (parseGetRequest req)
                     >>= first formatRelationError . addRelations schema allRels Nothing
                     >>= addJoinConditions schema allCols


            query = requestToQuery schema <$> apiRequest
            --countQuery = requestToCountQuery schema <$> apiRequest
            --queries = (,) <$> query <*> countQuery

    (["postgrest", "users"], "POST") -> do
      let user = decode reqBody :: Maybe AuthUser

      case user of
        Nothing -> return $ responseLBS status400 [jsonH] $
          encode . object $ [("message", String "Failed to parse user.")]
        Just u -> do
          _ <- addUser (cs $ userId u)
            (cs $ userPass u) (cs <$> userRole u)
          return $ responseLBS status201
            [ jsonH
            , (hLocation, "/postgrest/users?id=eq." <> cs (userId u))
            ] ""

    (["postgrest", "tokens"], "POST") ->
      case jwtSecret of
        "secret" -> return $ responseLBS status500 [jsonH] $
          encode . object $ [("message", String "JWT Secret is set as \"secret\" which is an unsafe default.")]
        _ -> do
          let user = decode reqBody :: Maybe AuthUser

          case user of
            Nothing -> return $ responseLBS status400 [jsonH] $
              encode . object $ [("message", String "Failed to parse user.")]
            Just u -> do
              setRole authenticator
              login <- signInRole (cs $ userId u) (cs $ userPass u)
              case login of
                LoginSuccess role uid ->
                  return $ responseLBS status201 [ jsonH ] $
                    encode . object $ [("token", String $ tokenJWT jwtSecret uid role)]
                _  -> return $ responseLBS status401 [jsonH] $
                  encode . object $ [("message", String "Failed authentication.")]


    ([table], "POST") -> do
      let echoRequested = hasPrefer "return=representation" --TODO!! do not request content at all in query if not echoRequested
      case insertQuery of
        Left e -> return $ responseLBS status400 [("Content-Type", "application/json")] $ cs e
        Right qs -> do
          let isSingle = either (const False) id returnSingle
              pKeys = map pkName $ filter (filterPk schema table) allPrKeys
              q = B.Stmt
                   (withSourceF qs <>
                   " SELECT " <>
                     (if isSingle then locationF pKeys else "null") <>
                     "," <>
                     countF <>
                     "," <>
                     (case contentType of
                        "text/csv" -> asCsvF
                        _     -> if isSingle then asJsonSingleF else asJsonF
                     ) <>
                   " " <>
                   fromF ( limitF Nothing ))
                   V.empty True

          row <- H.maybeEx q
          let (locationRaw, _ {-- queryTotal --}, bodyRaw) = fromMaybe (Just "" :: Maybe BL.ByteString, Just (0::Int), Just "" :: Maybe BL.ByteString) row
              body = fromMaybe "[]" bodyRaw
              locationH = fromMaybe "" locationRaw
          return $ responseLBS status201
            [
              contentTypeH,
              (hLocation, "/" <> cs table <> "?" <> cs locationH)
            ]
            $ if echoRequested then body else ""
        -- let qt = qualify table
      --     echoRequested = hasPrefer "return=representation"
      --     parsed :: Either String (V.Vector Text, V.Vector (V.Vector Value))
      --     parsed = if lookupHeader "Content-Type" == Just csvMT
      --       then do
      --         rows <- CSV.decode CSV.NoHeader reqBody
      --         if V.null rows then Left "CSV requires header"
      --           else Right (V.head rows, (V.map $ V.map $ parseCsvCell . cs) (V.tail rows))
      --       else eitherDecode reqBody >>= \val ->
      --         case val of
      --           Object obj -> Right .  second V.singleton .  V.unzip .  V.fromList $
      --             M.toList obj
      --           _ -> Left "Expecting single JSON object or CSV rows"
      -- case parsed of
      --   Left err -> return $ responseLBS status400 [] $
      --     encode . object $ [("message", String $ "Failed to parse JSON payload. " <> cs err)]
      --   Right toBeInserted -> do
      --     rows :: [Identity Text] <- H.listEx $ uncurry (insertInto qt) toBeInserted
      --     let inserted :: [Object] = mapMaybe (decode . cs . runIdentity) rows
      --         pKeys = map pkName $ filter (filterPk schema table) allPrKeys
      --         responses = flip map inserted $ \obj -> do
      --           let primaries =
      --                 if Prelude.null pKeys
      --                   then obj
      --                   else M.filterWithKey (const . (`elem` pKeys)) obj
      --           let params = urlEncodeVars
      --                 $ map (\t -> (cs $ fst t, cs (paramFilter $ snd t)))
      --                 $ sortBy (comparing fst) $ M.toList primaries
      --           responseLBS status201
      --             [ jsonH
      --             , (hLocation, "/" <> cs table <> "?" <> cs params)
      --             ] $ if echoRequested then encode obj else ""
      --     return $ multipart status201 responses

      where
        res = parsePostRequest req reqBody
        apiRequest = snd <$> res
        returnSingle = fst <$> res
        insertQuery = requestToQuery schema <$> apiRequest

        -- localWithT (B.Stmt eq ep epre) v (B.Stmt wq wp wpre) =
        --   B.Stmt ("WITH " <> v <> " AS (" <> eq <> ") " <> wq)
        --     (ep <> wp)
        --     (epre && wpre)
        --
        -- query = localWithT
        --     <$> insertQuery
        --     <*> pure "k"
        --     <*> pure (
        --       B.Stmt "SELECT " V.empty True <>
        --       bodyForAccept contentType (QualifiedIdentifier "" "k") (B.Stmt "SELECT * FROM k" V.empty True)
        --       )
        --       -- TODO! csv does not work because k is not a real table


    (["rpc", proc], "POST") -> do
      let qi = QualifiedIdentifier schema (cs proc)
      exists <- doesProcExist schema proc
      if exists
        then do
          let call = B.Stmt "select " V.empty True <>
                asJson (callProc qi $ fromMaybe M.empty (decode reqBody))
          body :: Maybe (Identity Text) <- H.maybeEx call
          return $ responseLBS status200 [jsonH]
            (cs $ fromMaybe "[]" $ runIdentity <$> body)
        else return $ responseLBS status404 [] ""

      -- check that proc exists
      -- check that arg names are all specified
      -- select * from public.proc(a := "foo"::undefined) where whereT limit limitT

    ([table], "PUT") ->
      handleJsonObj reqBody $ \obj -> do
        let qt = qualify table
            pKeys = map pkName $ filter (filterPk schema table) allPrKeys
            specifiedKeys = map (cs . fst) qq
        if S.fromList pKeys /= S.fromList specifiedKeys
          then return $ responseLBS status405 []
            "You must speficy all and only primary keys as params"
          else do
            let tableCols = map (cs . colName) $ filter (filterCol schema table) allCols
                cols = map cs $ M.keys obj
            if S.fromList tableCols == S.fromList cols
              then do
                let vals = M.elems obj
                H.unitEx $ iffNotT
                  (whereT qt qq $ update qt cols vals)
                  (insertSelect qt cols vals)
                return $ responseLBS status204 [ jsonH ] ""

              else return $ if Prelude.null tableCols
                then responseLBS status404 [] ""
                else responseLBS status400 []
                  "You must specify all columns in PUT request"

    ([table], "PATCH") ->
      handleJsonObj reqBody $ \obj -> do
        let qt = qualify table
            up = returningStarT
              . whereT qt qq
              $ update qt (map cs $ M.keys obj) (M.elems obj)
            patch = withT up "t" $ B.Stmt
              "select count(t), array_to_json(array_agg(row_to_json(t)))::character varying"
              V.empty True

        row <- H.maybeEx patch
        let (queryTotal, body) =
              fromMaybe (0 :: Int, Just "" :: Maybe Text) row
            r = contentRangeH 0 (queryTotal-1) (Just queryTotal)
            echoRequested = hasPrefer "return=representation"
            s = case () of _ | queryTotal == 0 -> status404
                             | echoRequested -> status200
                             | otherwise -> status204
        return $ responseLBS s [ jsonH, r ] $ if echoRequested then cs $ fromMaybe "[]" body else ""

    ([table], "DELETE") -> do
      let qt = qualify table
          del = countT
            . returningStarT
            . whereT qt qq
            $ deleteFrom qt
      row <- H.maybeEx del
      let (Identity deletedCount) = fromMaybe (Identity 0 :: Identity Int) row
      return $ if deletedCount == 0
        then responseLBS status404 [] ""
        else responseLBS status204 [("Content-Range", "*/"<> cs (show deletedCount))] ""

    (_, _) ->
      return $ responseLBS status404 [] ""

  where
    allTabs = tables dbstructure
    allRels = relations dbstructure
    allCols = columns dbstructure
    allPrKeys = primaryKeys dbstructure
    filterCol sc table (Column{colSchema=s, colTable=t}) =  s==sc && table==t
    filterCol _ _ _ =  False
    filterPk sc table pk = sc == pkSchema pk && table == pkTable pk

    filterTableAcl :: Text -> Table -> Bool
    filterTableAcl r (Table{tableAcl=a}) = r `elem` a
    path          = pathInfo req
    verb          = requestMethod req
    qq            = queryString req
    qualify       = QualifiedIdentifier schema
    hdrs          = requestHeaders req
    lookupHeader  = flip lookup hdrs
    hasPrefer val = any (\(h,v) -> h == "Prefer" && v == val) hdrs
    accept        = lookupHeader hAccept
    schema        = cs $ configSchema conf
    jwtSecret     = cs $ configJwtSecret conf
    range         = rangeRequested hdrs
    allOrigins    = ("Access-Control-Allow-Origin", "*") :: Header
    contentType   = fromMaybe "application/json" $ contentTypeForAccept accept
    contentTypeH  = (hContentType, contentType)

sqlError :: t
sqlError = undefined

isSqlError :: t
isSqlError = undefined

rangeStatus :: Int -> Int -> Maybe Int -> Status
rangeStatus _ _ Nothing = status200
rangeStatus frm to (Just total)
  | frm > total            = status416
  | (1 + to - frm) < total = status206
  | otherwise               = status200

contentRangeH :: Int -> Int -> Maybe Int -> Header
contentRangeH frm to total =
    ("Content-Range", cs headerValue)
    where
      headerValue   = rangeString <> "/" <> totalString
      rangeString
        | totalNotZero && fromInRange = show frm <> "-" <> cs (show to)
        | otherwise = "*"
      totalString   = fromMaybe "*" (show <$> total)
      totalNotZero  = fromMaybe True ((/=) 0 <$> total)
      fromInRange   = frm <= to

jsonMT :: BS.ByteString
jsonMT = "application/json"

csvMT :: BS.ByteString
csvMT = "text/csv"

allMT :: BS.ByteString
allMT = "*/*"

jsonH :: Header
jsonH = (hContentType, jsonMT)

contentTypeForAccept :: Maybe BS.ByteString -> Maybe BS.ByteString
contentTypeForAccept accept
  | isNothing accept || has allMT || has jsonMT = Just jsonMT
  | has csvMT = Just csvMT
  | otherwise = Nothing
  where
    Just acceptH = accept
    findInAccept = flip find $ parseHttpAccept acceptH
    has          = isJust . findInAccept . BS.isPrefixOf

bodyForAccept :: BS.ByteString -> QualifiedIdentifier  -> StatementT
bodyForAccept contentType table
  | contentType == csvMT = asCsvWithCount table
  | otherwise = asJsonWithCount -- defaults to JSON

handleJsonObj :: BL.ByteString -> (Object -> H.Tx P.Postgres s Response)
              -> H.Tx P.Postgres s Response
handleJsonObj reqBody handler = do
  let p = eitherDecode reqBody
  case p of
    Left err ->
      return $ responseLBS status400 [jsonH] jErr
      where
        jErr = encode . object $
          [("message", String $ "Failed to parse JSON payload. " <> cs err)]
    Right (Object o) -> handler o
    Right _ ->
      return $ responseLBS status400 [jsonH] jErr
      where
        jErr = encode . object $
          [("message", String "Expecting a JSON object")]

parseCsvCell :: BL.ByteString -> Value
parseCsvCell s = if s == "NULL" then Null else String $ cs s

multipart :: Status -> [Response] -> Response
multipart _ [] = responseLBS status204 [] ""
multipart _ [r] = r
multipart s rs =
  responseLBS s [(hContentType, "multipart/mixed; boundary=\"postgrest_boundary\"")] $
    BL.intercalate "\n--postgrest_boundary\n" (map renderResponseBody rs)

  where
    renderHeader :: Header -> BL.ByteString
    renderHeader (k, v) = cs (original k) <> ": " <> cs v

    renderResponseBody :: Response -> BL.ByteString
    renderResponseBody (ResponseBuilder _ headers b) =
      BL.intercalate "\n" (map renderHeader headers)
        <> "\n\n" <> BB.toLazyByteString b
    renderResponseBody _ = error
      "Unable to create multipart response from non-ResponseBuilder"


formatRelationError :: Text -> Text
formatRelationError e = cs $ encode $ object [
  "mesage" .= ("could not find foreign keys between these entities"::String),
  "details" .= e]
formatParserError :: ParseError -> Text
formatParserError e = cs $ encode $ object [
  "message" .= message,
  "details" .= details]
  where
     message = show (errorPos e)
     details = strip $ replace "\n" " " $ cs
       $ showErrorMessages "or" "unknown parse error" "expecting" "unexpected" "end of input" (errorMessages e)
--parsePostRequest :: Request -> BL.ByteString -> Either String (V.Vector Text, V.Vector (V.Vector Value))
parsePostRequest :: Request -> BL.ByteString -> Either Text (Bool, ApiRequest)
parsePostRequest httpRequest reqBody =
  (,) <$> returnSingle <*> node
  where
    node = Node <$> apiNode <*> pure []
    apiNode = (,) <$> (Insert rootTableName <$> flds <*> vals) <*> pure (rootTableName, Nothing)
    flds =  join $ first formatParserError . mapM (parseField . cs) <$> (fst <$> parsed)
    vals = snd <$> parsed
    parseField f = parse pField ("failed to parse field <<"++f++">>") f
    parsed :: Either Text ([Text],[[Value]])
    parsed = first cs $
      (\v->
        if headerMatchesContent v
        then Right v
        else
          if isCsv
          then Left "CSV header does not match rows length"
          else Left "The number of keys in objects do not match"
      ) =<<
      if isCsv
      then do
        rows <- (map V.toList . V.toList) <$> CSV.decode CSV.NoHeader reqBody
        if null rows then Left "CSV requires header"
          else Right (head rows, (map $ map $ parseCsvCell . cs) (tail rows))
      else eitherDecode reqBody >>= \val -> convertJson val
    -- jsn = eitherDecode reqBody
    -- returnSingle = first cs $ jsn >>= (\v->
    --   case v of
    --     Object _  -> Right True
    --     _         -> Right False
    --   )
    returnSingle = (==1) . length . snd <$> parsed
    hdrs          = requestHeaders httpRequest
    lookupHeader  = flip lookup hdrs
    rootTableName = cs $ head $ pathInfo httpRequest -- TODO unsafe head
    isCsv = lookupHeader "Content-Type" == Just csvMT

headerMatchesContent :: ([Text], [[Value]]) -> Bool
headerMatchesContent (header, vals) = all ( (headerLength ==) . length) vals
  where headerLength = length header

convertJson :: Value -> Either String ([Text],[[Value]])
convertJson v = (,) <$> (header <$> normalized) <*> (vals <$> normalized)
  where
    invalidMsg = "Expecting single JSON object or JSON array of objects"
    normalized :: Either String [(Text, [Value])]
    normalized = groupByKey =<< normalizeValue v

    vals :: [(Text, [Value])] -> [[Value]]
    vals a = transpose $ map snd a

    header :: [(Text, [Value])] -> [Text]
    header = map fst

    groupByKey :: Value -> Either String [(Text,[Value])]
    groupByKey (Array a) = M.toList . foldr (M.unionWith (++)) (M.fromList []) <$> maps
      where
        maps :: Either String [M.HashMap Text [Value]]
        maps = mapM getElems $ V.toList a
        getElems (Object o) = Right $ M.map (:[]) o
        getElems _ = Left invalidMsg
    groupByKey _ = Left invalidMsg

    normalizeValue :: Value -> Either String Value
    normalizeValue val =
      case val of
        Object obj  -> Right $ Array (V.fromList[Object obj])
        a@(Array _) -> Right a
        _ -> Left invalidMsg

parseGetRequest :: Request -> Either ParseError ApiRequest
parseGetRequest httpRequest =
  foldr addFilter <$> (addOrder <$> apiRequest <*> ord) <*> flts
  where
    apiRequest = parse (pRequestSelect rootTableName) ("failed to parse select parameter <<"++selectStr++">>") $ cs selectStr
    addOrder (Node (q,i) f) o = Node (q{order=o}, i) f
    flts = mapM pRequestFilter whereFilters
    rootTableName = cs $ head $ pathInfo httpRequest -- TODO unsafe head
    qString = [(cs k, cs <$> v)|(k,v) <- queryString httpRequest]
    orderStr = join $ lookup "order" qString
    ord = traverse (parse pOrder ("failed to parse order parameter <<"++fromMaybe "" orderStr++">>")) orderStr
    selectStr = fromMaybe "*" $ fromMaybe (Just "*") $ lookup "select" qString --in case the parametre is missing or empty we default to *
    whereFilters = [ (k, fromJust v) | (k,v) <- qString, k `notElem` ["select", "order"], isJust v ]

addFilter :: (Path, Filter) -> ApiRequest -> ApiRequest
addFilter ([], flt) (Node (q@(Select {where_=flts}), i) forest) = Node (q {where_=flt:flts}, i) forest
addFilter (path, flt) (Node rn forest) =
  case targetNode of
    Nothing -> Node rn forest -- the filter is silenty dropped in the Request does not contain the required path
    Just tn -> Node rn (addFilter (remainingPath, flt) tn:restForest)
  where
    targetNodeName:remainingPath = path
    (targetNode,restForest) = splitForest targetNodeName forest
    splitForest name forst =
      case maybeNode of
        Nothing -> (Nothing,forest)
        Just node -> (Just node, delete node forest)
      where maybeNode = find ((name==).fst.snd.rootLabel) forst


data TableOptions = TableOptions {
  tblOptcolumns :: [Column]
, tblOptpkey    :: [Text]
}

instance ToJSON TableOptions where
  toJSON t = object [
      "columns" .= tblOptcolumns t
    , "pkey"   .= tblOptpkey t ]
