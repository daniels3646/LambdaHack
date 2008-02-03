module Display.Vty
  (startup, shutdown, setHalfBright,
   display, nextEvent, setBG, setFG, Session, blue, magenta, yellow, attr, Attr) where

import Graphics.Vty as V
import Data.List as L
import Data.Char
import qualified Data.ByteString as BS

import Geometry

type Session = V.Vty

startup :: (Session -> IO ()) -> IO ()
startup k =
  do
    session <- V.mkVty
    k session

display :: Area -> Session -> (Loc -> (Attr, Char)) -> String -> String -> IO ()
display ((y0,x0),(y1,x1)) vty f msg status =
    let img = (foldr (<->) V.empty . 
               L.map (foldr (<|>) V.empty . 
                      L.map (\ (x,y) -> let (a,c) = f (y,x) in renderChar a c)))
              [ [ (x,y) | x <- [x0..x1] ] | y <- [y0..y1] ]
    in  V.update vty (Pic NoCursor 
         ((renderBS attr (BS.pack (L.map (fromIntegral . ord) (toWidth (x1-x0+1) msg)))) <->
          img <-> 
          (renderBS attr (BS.pack (L.map (fromIntegral . ord) (toWidth (x1-x0+1) status))))))

toWidth :: Int -> String -> String
toWidth n x = take n (x ++ repeat ' ')

nextEvent :: Session -> IO String
nextEvent session =
  do
    e <- V.getEvent session
    case e of
      V.EvKey (KASCII '<') [] -> return "less"
      V.EvKey (KASCII '>') [] -> return "greater"
      V.EvKey (KASCII c) []   -> return [c]
      V.EvKey KEsc []         -> return "Escape"
      _                       -> nextEvent session
