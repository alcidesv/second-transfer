{-# LANGUAGE ExistentialQuantification, TemplateHaskell #-}
{-# OPTIONS_HADDOCK hide #-}
module SecondTransfer.MainLoop.PushPullType (
    PushAction
    ,PullAction
    ,Attendant
    ,CloseAction
    ,AttendantCallbacks(..)

    ,pushAction_AtC
    ,pullAction_AtC
    ,closeAction_AtC
    ,bestEffortPullAction_AtC
    ) where


import Control.Lens

import qualified Data.ByteString              as B
import qualified Data.ByteString.Lazy         as LB

-- | Callback type to push data to a channel. Part of this
--   interface is the abstract exception type IOProblem. Throw an
--   instance of it from here to notify the session that the connection has
--   been broken. There is no way to signal "normal termination", since
--   HTTP/2's normal termination can be observed at a higher level when a
--   GO_AWAY frame is seen.
type PushAction  = LB.ByteString -> IO ()

-- | Callback type to pull data from a channel in a best-effort basis.
--   When the first argument is True, the data-providing backend can
--   block if the input buffers are empty and await for new data.
--   Otherwise, it will return immediately with an empty ByteString
type BestEffortPullAction = Bool -> IO B.ByteString

-- | Callback type to pull data from a channel. The same
--   as to PushAction applies to exceptions thrown from
--   there. The first argument is the number of bytes to
--   pull from the medium. Barring exceptions, we always
--   know how many bytes we are expecting with HTTP/2.
type PullAction  = Int -> IO B.ByteString

-- | Callback that the session calls to realease resources
--   associated with the channels. Take into account that your
--   callback should be able to deal with non-clean shutdowns
--   also, for example, if the connection to the remote peer
--   is severed suddenly.
type CloseAction = IO ()


data AttendantCallbacks = AttendantCallbacks {
    _pushAction_AtC               :: PushAction,
    _pullAction_AtC               :: PullAction,
    _bestEffortPullAction_AtC     :: BestEffortPullAction,
    _closeAction_AtC              :: CloseAction
    }

makeLenses ''AttendantCallbacks

-- | A function which takes three arguments: the first one says
--   how to send data (on a socket or similar transport), and the second one how
--   to receive data on the transport. The third argument encapsulates
--   the sequence of steps needed for a clean shutdown.
--
--   You can implement one of these to let somebody else  supply the
--   push, pull and close callbacks. For example, 'tlsServeWithALPN' will
--   supply these arguments to an 'Attendant'.
--
--   Attendants encapsulate all the session book-keeping functionality,
--   which for HTTP/2 is quite complicated. You use the functions
--   http**Attendant
--   to create one of these from a 'SecondTransfer.Types.CoherentWorker'.
--
--   This library supplies two of such Attendant factories,
--   'SecondTransfer.Http1.http11Attendant' for
--   HTTP 1.1 sessions, and 'SecondTransfer.Http2.http2Attendant' for HTTP/2 sessions.
type Attendant = AttendantCallbacks -> IO ()
