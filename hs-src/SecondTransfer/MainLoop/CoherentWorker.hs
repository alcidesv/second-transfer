{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}
{-# LANGUAGE FunctionalDependencies, FlexibleInstances, DeriveDataTypeable  #-}
-- | A CoherentWorker is one that doesn't need to compute everything at once...
--   This one is simpler than the SPDY one, because it enforces certain order....



module SecondTransfer.MainLoop.CoherentWorker(
    getHeaderFromFlatList
    , nullFooter

    , HeaderName
    , HeaderValue
    , Header
    , Headers
    , FinalizationHeaders
    , Request(..)
    , Footers
    , Perception(..)
    , Effect(..)
    , AwareWorker
    , PrincipalStream
    , PushedStreams
    , PushedStream
    , DataAndConclusion
    , CoherentWorker
    , InputDataStream
    , TupledPrincipalStream

    , middlePauseForDelivery_Ef
    , headers_RQ
    , inputData_RQ
    , perception_RQ
    , headers_PS
    , pushedStreams_PS
    , dataAndConclusion_PS
    , effect_PS
    , startedTime_Pr
    , streamId_Pr
    , sessionId_Pr

    , defaultEffects
    , coherentToAwareWorker

    , tupledPrincipalStreamToPrincipalStream
    , requestToTupledRequest
    ) where


import           Control.Lens
import qualified Data.ByteString   as B
import           Data.Conduit
import           Data.Foldable     (find)
import           System.Clock      (TimeSpec)


-- | The name part of a header
type HeaderName = B.ByteString

-- | The value part of a header
type HeaderValue = B.ByteString

-- | The complete header
type Header = (HeaderName, HeaderValue)

-- |List of headers. The first part of each tuple is the header name
-- (be sure to conform to the HTTP/2 convention of using lowercase)
-- and the second part is the headers contents. This list needs to include
-- the special :method, :scheme, :authority and :path pseudo-headers for
-- requests; and :status (with a plain numeric value represented in ascii digits)
-- for responses.
type Headers = [Header]

-- |This is a Source conduit (see Haskell Data.Conduit library from Michael Snoyman)
-- that you can use to retrieve the data sent by the client piece-wise.
type InputDataStream = Source IO B.ByteString


-- | Data related to the request
data Perception = Perception {
  -- Monotonic time close to when the request was first seen in
  -- the processing pipeline.
  _startedTime_Pr :: TimeSpec,
  -- The HTTP/2 stream id. Or the serial number of the request in an
  -- HTTP/1.1 session.
  _streamId_Pr :: Int,
  -- You know better than to use this for normal web request
  -- processing. But otherwise a number uniquely identifying the session. 
  _sessionId_Pr :: Int
  }

makeLenses ''Perception


-- | A request is a set of headers and a request body....
-- which will normally be empty, except for POST and PUT requests. But
-- this library enforces none of that.
data Request = Request {
     _headers_RQ    :: ! Headers,
     _inputData_RQ  :: Maybe InputDataStream,
     _perception_RQ :: ! Perception
  }

makeLenses ''Request

-- | Finalization headers. If you don't know what they are, chances are
--   that you don't need to worry about them for now. The support in this
--   library for those are at best sketchy.
type FinalizationHeaders = Headers

-- | Finalization headers
type Footers = FinalizationHeaders

-- | A list of pushed streams.
--   Notice that a list of IO computations is required here. These computations
--   only happen when and if the streams are pushed to the client.
--   The lazy nature of Haskell helps to avoid unneeded computations if the
--   streams are not going to be sent to the client.
type PushedStreams = [ IO PushedStream ]

-- | A pushed stream, represented by a list of request headers,
--   a list of response headers, and the usual response body  (which
--   may include final footers (not implemented yet)).
type PushedStream = (Headers, Headers, DataAndConclusion)


-- | A source-like conduit with the data returned in the response. The
--   return value of the conduit is a list of footers. For now that list can
--   be anything (even bottom), I'm not handling it just yet.
type DataAndConclusion = ConduitM () B.ByteString IO Footers

-- | Sometimes a response needs to be handled a bit specially,
--   for example by reporting delivery details back to the worker
data Effect = Effect {
  -- Pause time in microseconds for deliverying frames of this
  -- stream. Zero is no pause and it is a
  -- special case since no call is made then
  _middlePauseForDelivery_Ef :: Int
  }

makeLenses ''Effect

defaultEffects :: Effect
defaultEffects = Effect {
   _middlePauseForDelivery_Ef = 0
   }


-- | You use this type to answer a request. The `Headers` are thus response
--   headers and they should contain the :status pseudo-header. The `PushedStreams`
--   is a list of pushed streams...(I don't thaink that I'm handling those yet)
data PrincipalStream = PrincipalStream {
  _headers_PS              :: Headers,
  _pushedStreams_PS        :: PushedStreams,
  _dataAndConclusion_PS    :: DataAndConclusion,
  _effect_PS               :: Effect
  }

makeLenses ''PrincipalStream


-- | Main type of this library. You implement one of these for your server.
--   This is a callback that the library calls as soon as it has
--   all the headers of a request. For GET requests that's the entire request
--   basically, but for POST and PUT requests this is just before the data
--   starts arriving to the server.
--
--   It is important that you consume the data in the cases where there is an
--   input stream, otherwise the memory is lost for the duration of the request,
--   and a malicious client can use that.
--
--   Also, notice that when handling requests your worker can be interrupted with
--   an asynchronous exception of type 'StreamCancelledException', if the peer
--   cancels the stream
type AwareWorker = Request -> IO PrincipalStream

-- | A CoherentWorker is a less fuzzy worker, but less aware.
type CoherentWorker =  (Headers, Maybe InputDataStream) -> IO (Headers, PushedStreams, DataAndConclusion)

-- | Not exactly equivalent of the prinicipal stream
type TupledPrincipalStream = (Headers, PushedStreams, DataAndConclusion)

type TupledRequest = (Headers, Maybe InputDataStream)


tupledPrincipalStreamToPrincipalStream :: TupledPrincipalStream -> PrincipalStream
tupledPrincipalStreamToPrincipalStream (headers, pushed_streams, data_and_conclusion) = PrincipalStream
      {
        _headers_PS = headers,
        _pushedStreams_PS = pushed_streams,
        _dataAndConclusion_PS = data_and_conclusion,
        _effect_PS = defaultEffects
      }

requestToTupledRequest ::  Request -> TupledRequest
requestToTupledRequest req =
      (req ^. headers_RQ,
       req ^. inputData_RQ )

coherentToAwareWorker :: CoherentWorker -> AwareWorker
coherentToAwareWorker w r =
    fmap tupledPrincipalStreamToPrincipalStream $ w . requestToTupledRequest $ r

-- | Gets a single header from the list
getHeaderFromFlatList :: Headers -> B.ByteString -> Maybe B.ByteString
getHeaderFromFlatList unvl bs =
    case find (\ (x,_) -> x==bs ) unvl of
        Just (_, found_value)  -> Just found_value

        Nothing                -> Nothing


-- | If you want to skip the footers, i.e., they are empty, use this
--   function to convert an ordinary Source to a DataAndConclusion.
nullFooter :: Source IO B.ByteString -> DataAndConclusion
nullFooter s = s =$= go
  where
    go = do
        i <- await
        case i of
            Nothing ->
                return []

            Just ii -> do
                yield ii
                go
