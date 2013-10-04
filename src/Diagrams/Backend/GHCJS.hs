{-# LANGUAGE TypeFamilies
           , MultiParamTypeClasses
           , FlexibleInstances
           , FlexibleContexts
           , TypeSynonymInstances
           , DeriveDataTypeable
           , ViewPatterns
           , OverloadedStrings
           , TypeHoles
           , InstanceSigs
  #-}

module Diagrams.Backend.GHCJS
  ( Canvas(..)
  , Options(..)
  ) where

import           Control.Monad        (when)
import qualified Data.Foldable        as F
import           Data.Maybe           (catMaybes, maybe)
import           Data.Monoid          ((<>))
import           Data.Typeable
import qualified Data.Text            as T
import           Control.Monad.Reader

import           Diagrams.Prelude     hiding ((<>))
import           Diagrams.TwoD.Adjust (adjustDia2D)
import           Diagrams.TwoD.Path   (getFillRule, getClip, Clip)
import           Diagrams.TwoD.Text   (getFont, getFontSize)
import qualified Diagrams.TwoD.Text   as D
import           Diagrams.Segment

import qualified Graphics.Rendering.GHCJS as G

import Debug.Trace

-- | This data declaration is simply used as a token to distinguish this
-- rendering engine.
data Canvas = Canvas deriving Typeable

instance Monoid (Render Canvas R2) where
  mempty  = C $ return defRenderInfo
  (C c1) `mappend` (C c2) = C (c1 >> c2)

-- | Skip filling after drawing this subdiagram?
data RenderInfo = I { getIgnoreFill :: Bool }

defRenderInfo :: RenderInfo
defRenderInfo = I False

instance Backend Canvas R2 where
    data Render  Canvas R2 = C (G.Render RenderInfo)
    type Result  Canvas R2 = IO ()
    data Options Canvas R2 = CanvasOptions
            { canvasSize   :: SizeSpec2D   -- ^ the requested size
            , context      :: G.Context    -- ^ drawing context to render to
            }

    withStyle _ s t (C r) = C $ do
        handleClipping (getAttr s)
        let r' = fmap getIgnoreFill r :: G.Render Bool
        G.withStyle (canvasTransf t) (canvasStyle s) r'
        return defRenderInfo

    doRender _ (CanvasOptions _ c) (C r) = void $ G.doRender c r

    adjustDia c opts d = adjustDia2D canvasSize setCanvasSize c opts
                         (d # reflectY # fcA transparent # lw 0.01)
        where setCanvasSize sz o = o { canvasSize = sz }

renderC :: (Renderable a Canvas, V a ~ R2) => a -> G.Render RenderInfo
renderC a = case (render Canvas a) of C r -> r

canvasStyle :: Style v -> G.Render ()
canvasStyle s = foldr (>>) (return ())
              . catMaybes $ [ handle fColor
                            , handle lColor
                            , handle lWidth
                            , handle lJoin
                            , handle lCap
                            , handle opacity_
                            , handle fRule
                            , handle dashing_
                            , handleFont
                            ]
  where handle :: (AttributeClass a) => (a -> G.Render ()) -> Maybe (G.Render ())
        handle f = f `fmap` getAttr s
        lColor   = G.strokeColor . getLineColor
        fColor   = G.fillColor   . getFillColor
        lWidth   = G.lineWidth   . getLineWidth
        lCap     = G.lineCap     . getLineCap
        lJoin    = G.lineJoin    . getLineJoin
        opacity_ = G.globalAlpha . getOpacity
        fRule    = G.setFill     . getFillRule
        dashing_ = G.dashing     . getDashing
        handleFont = let fontFamily' = getAttr s :: Maybe (D.Font)
                         fontSize'   = getAttr s :: Maybe (D.FontSize)
                         fontSlant'  = getAttr s :: Maybe (D.FontSlantA)
                         fontWeight' = getAttr s :: Maybe (D.FontWeightA)
                         fontFamily  = maybe "Arial" getFont fontFamily'
                         fontSize    = maybe 10 getFontSize fontSize'
                         fontSlant   = maybe D.FontSlantNormal D.getFontSlant fontSlant'
                         fontWeight  = maybe D.FontWeightNormal D.getFontWeight fontWeight'
                     in Just $ G.setFont $ dbg $
                        slantToCss fontSlant
                        <> weightToCss fontWeight
                        <> T.pack (show fontSize)
                        <> "px "
                        <> (T.pack fontFamily)

slantToCss :: D.FontSlant -> T.Text
slantToCss D.FontSlantNormal = "" -- " normal "
slantToCss D.FontSlantItalic = " italic "
slantToCss D.FontSlantOblique = " oblique "

weightToCss :: D.FontWeight -> T.Text
weightToCss D.FontWeightNormal = "" -- " normal "
weightToCss D.FontWeightBold = " bold "

dbg :: Show a => a -> a
dbg x = traceShow x x

handleClipping :: Maybe Clip -> G.Render ()
handleClipping Nothing  = return ()
handleClipping (Just c) = clipCanv (getClip c)

clipCanv :: [Path R2] -> G.Render ()
clipCanv pths = mapM_ renderPath pths >> G.clip

renderPath :: Path R2 -> G.Render ()
renderPath (Path trs) = G.newPath >> F.mapM_ renderTrail trs

canvasTransf :: Transformation R2 -> G.Render ()
canvasTransf t = do
    G.setTransform a1 a2 b1 b2 c1 c2
  where
    (a1,a2,b1,b2,c1,c2) = getMatrix t

getMatrix :: Transformation R2
          -> (Double, Double, Double, Double, Double, Double)
getMatrix t = (a1,a2,b1,b2,c1,c2)
 where
  (unr2 -> (a1,a2)) = apply t unitX
  (unr2 -> (b1,b2)) = apply t unitY
  (unr2 -> (c1,c2)) = transl t

instance Renderable (Segment Closed R2) Canvas where
    render _ seg = C $ renderSeg seg
                    >> return defRenderInfo

instance Renderable (Trail R2) Canvas where
    render c = render c . pathFromTrail

instance Renderable (Path R2) Canvas where
    render _ p@(Path trs) = C $ do
        renderPath p
        return $ I $ any (isLine . unLoc) trs

instance Renderable D.Text Canvas where
    render _ (D.Text tt a s) = C $ do
        liftIO $ print $ getMatrix $ tt
        liftIO $ print $ getMatrix $ reflectionY
        liftIO $ print $ getMatrix $ tt <> reflectionY
        G.tempState $ do
            G.setTransform a1 a2 b1 b2 c1 c2
            G.fillText (T.pack s)
        return $ I False
      where
        (a1,a2,b1,b2,c1,c2) = getMatrix (tt <> reflectionY)

renderTrail :: Located (Trail R2) -> G.Render ()
renderTrail (viewLoc -> (unp2 -> (x,y), t)) = do
    G.moveTo x y
    mapM_ renderC (trailSegments t)
    if isLoop t
      then G.closePath
      else return ()

renderSeg :: Segment Closed R2 -> G.Render ()
renderSeg (Linear (OffsetClosed v)) = uncurry G.relLineTo (unr2 v)
renderSeg (Cubic (unr2 -> (x1,y1))
                 (unr2 -> (x2,y2))
                 (OffsetClosed (unr2 -> (x3,y3))))
    = G.relCurveTo x1 y1 x2 y2 x3 y3
