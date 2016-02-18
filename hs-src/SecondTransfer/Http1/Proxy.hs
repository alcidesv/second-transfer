{-# LANGUAGE OverloadedStrings, TemplateHaskell, FunctionalDependencies, Rank2Types #-}
module SecondTransfer.Http1.Proxy (
                 ioProxyToConnection
        ) where

import           Control.Lens
import qualified Control.Exception                                         as E
import           Control.Monad                                             (when)
--import           Control.Monad.Morph                                       (hoist, lift)
import           Control.Monad.IO.Class                                    (liftIO, MonadIO)
--import qualified Control.Monad.Trans.Resource                              as ReT

import qualified Data.ByteString                                           as B
--import           Data.List                                                 (foldl')
import qualified Data.ByteString.Builder                                   as Bu
--import           Data.ByteString.Char8                                     (pack, unpack)
--import qualified Data.ByteString.Char8                                     as Ch8
import qualified Data.ByteString.Lazy                                      as LB
--import           Data.Char                                                 (toLower)
import           Data.Maybe                                                (fromMaybe)

import           Data.Conduit

--import           SecondTransfer.MainLoop.CoherentWorker                    (Headers)

import qualified SecondTransfer.Utils.HTTPHeaders                          as He
import           SecondTransfer.Http1.Types
import           SecondTransfer.Http1.Parse                                (
                                                                              headerListToHTTP1RequestText
                                                                            , methodHasRequestBody
                                                                            , methodHasResponseBody
                                                                            , newIncrementalHttp1Parser
                                                                            --, IncrementalHttp1Parser
                                                                            , Http1ParserCompletion(..)
                                                                            , addBytes
                                                                            , unwrapChunks
                                                                            , BodyStopCondition(..)
                                                                            )
import           SecondTransfer.IOCallbacks.Types
import           SecondTransfer.IOCallbacks.Coupling                       (sendSourceToIO)
import           SecondTransfer.Exception                                  (
                                                                              HTTP11SyntaxException(..)
                                                                            , NoMoreDataException
                                                                            , IOProblem (..)
                                                                            , GatewayAbortedException (..)
                                                                            , keyedReportExceptions
                                                                            -- , ignoreException
                                                                            -- , ioProblem
                                                                           )

#include "instruments.cpphs"



fragmentMaxLength :: Int
fragmentMaxLength = 16384


-- | Takes an IOCallbacks  and serializes a request (encoded HTTP/2 style in headers and streams)
--   on top of the callback, waits for the results, and returns the response. Notice that this proxy
--   may fail for any reason, do take measures and handle exceptions. Also, must headers manipulations
--   (e.g. removing the Connection header) are left to the upper layers. And this doesn't include
--   managing any kind of pipelining in the http/1.1 connection, however, close is not done, so
--   keep-alive (not pipelineing) should be OK.
ioProxyToConnection :: forall m . MonadIO m => IOCallbacks -> HttpRequest m -> m (HttpResponse m, IOCallbacks)
ioProxyToConnection ioc request =
  do
    let
       h1 = request ^. headers_Rq
       he1 = He.fromList h1
       he2 = He.combineAuthorityAndHost he1
       h3 = He.toList he2
       headers_bu = headerListToHTTP1RequestText h3
       separator = "\r\n"

       -- Contents of the head, including the separator, which should always
       -- be there.
       cnt1 = headers_bu `mappend` separator
       cnt1_lbz = Bu.toLazyByteString cnt1

       method = fromMaybe "GET" $ He.fetchHeader h3 ":method"

    -- Send the headers and the separator

    -- This code can throw an exception, in that case, just let it
    -- bubble. But the upper layer should deal with it.
    --LB.putStr cnt1_lbz
    --LB.putStr "\n"
    liftIO $ (ioc ^. pushAction_IOC) cnt1_lbz

    -- Send the rest only if the method has something ....
    if methodHasRequestBody method
      then
        -- We also need to send the body
        sendSourceToIO  (mapOutput LB.fromStrict $ request ^. body_Rq)  ioc
      else
        return ()

    -- So, say that we are here, that means we haven't exploded
    -- in the process of sending this request. now let's Try to
    -- fetch the answer...
    let
        incremental_http_parser = newIncrementalHttp1Parser

        -- pump0 :: IncrementalHttp1Parser -> m Http1ParserCompletion
        pump0 p =
         do
            some_bytes <- liftIO $ (ioc ^. bestEffortPullAction_IOC) True
            let completion = addBytes p some_bytes
            case completion of
               MustContinue_H1PC new_parser -> pump0 new_parser

               -- In any other case, just return
               a -> return a

        pumpout :: MonadIO m => B.ByteString -> Int -> Source m B.ByteString
        pumpout fragment n = do
            when (B.length fragment > 0) $  yield fragment
            when (n > 0 ) $ pull n

        pull :: MonadIO m => Int -> Source m B.ByteString
        pull n
          | n > fragmentMaxLength = do

            either_ioproblem_or_s <- liftIO $ keyedReportExceptions "pll-" $ E.try  $ (ioc ^. pullAction_IOC ) fragmentMaxLength
            s <- case either_ioproblem_or_s :: Either IOProblem B.ByteString of
                Left _exc -> liftIO $ E.throwIO GatewayAbortedException
                Right datum -> return datum
            yield s
            pull ( n - fragmentMaxLength )

          | otherwise = do

            either_ioproblem_or_s <- liftIO $ keyedReportExceptions "pla-" $ E.try  $ (ioc ^. pullAction_IOC ) n
            s <- case either_ioproblem_or_s :: Either IOProblem B.ByteString of
                Left _exc -> liftIO $ E.throwIO GatewayAbortedException
                Right datum -> return datum
            yield s
            -- and finish...

        pull_forever :: MonadIO m => Source m B.ByteString
        pull_forever = do
            either_ioproblem_or_s <- liftIO $ keyedReportExceptions "plc-" $ E.try  $ (ioc ^. bestEffortPullAction_IOC ) True
            s <- case either_ioproblem_or_s :: Either IOProblem B.ByteString of
                Left _exc -> liftIO $ E.throwIO GatewayAbortedException
                Right datum -> return datum
            yield s

        unwrapping_chunked :: MonadIO m => B.ByteString -> Source m B.ByteString
        unwrapping_chunked leftovers =
            (do
                yield leftovers
                pull_forever
            ) =$= unwrapChunks

        pump_until_exception fragment = do

            if B.length fragment > 0
              then do
                yield fragment
                pump_until_exception mempty
              else do
                s <- liftIO $ keyedReportExceptions "ue-" $ E.try $ (ioc ^. bestEffortPullAction_IOC) True
                case (s :: Either NoMoreDataException B.ByteString) of
                    Left _ -> do
                        return ()

                    Right datum -> do
                        yield datum
                        pump_until_exception mempty

    parser_completion <- pump0 incremental_http_parser

    case parser_completion of

        OnlyHeaders_H1PC headers leftovers -> do
            when (B.length leftovers > 0) $ do
                return ()
            return (HttpResponse {
                _headers_Rp = headers
              , _body_Rp = return ()
                }, ioc)

        HeadersAndBody_H1PC headers (UseBodyLength_BSC n) leftovers -> do
            --  HEADs must be handled differently!
            if methodHasResponseBody method
              then
                return (HttpResponse {
                    _headers_Rp = headers
                  , _body_Rp = pumpout leftovers (n - (fromIntegral $ B.length leftovers ) )
                    }, ioc)
              else
                return (HttpResponse {
                    _headers_Rp = headers
                  , _body_Rp = return ()
                    }, ioc)


        HeadersAndBody_H1PC headers Chunked_BSC  leftovers -> do
            --  HEADs must be handled differently!
            if methodHasResponseBody method
              then
                return (HttpResponse {
                    _headers_Rp = headers
                  , _body_Rp = unwrapping_chunked leftovers
                    },ioc)
              else
                return (HttpResponse {
                    _headers_Rp = headers
                  , _body_Rp = return ()
                    },ioc)


        HeadersAndBody_H1PC _headers SemanticAbort_BSC  _leftovers -> do
            --  HEADs must be handled differently!
            liftIO . E.throwIO $ HTTP11SyntaxException "SemanticAbort:SomethingAboutHTTP/1.1WasNotRight"


        HeadersAndBody_H1PC headers ConnectionClosedByPeer_BSC leftovers -> do
            -- The parser will assume that most responses have a body in the absence of
            -- content-length, and that's probably as well. We work around that for
            -- "HEAD" kind responses
            if methodHasResponseBody method
              then
                return (HttpResponse {
                    _headers_Rp = headers
                  , _body_Rp = pump_until_exception leftovers
                    },ioc)
              else
                return (HttpResponse {
                    _headers_Rp = headers
                  , _body_Rp = return ()
                    },ioc)

        MustContinue_H1PC _ ->
            error "UnexpectedIncompleteParse"

        -- TODO: See what happens when this exception passes from place to place.
        RequestIsMalformed_H1PC msg -> do
            liftIO . E.throwIO $ HTTP11SyntaxException msg
