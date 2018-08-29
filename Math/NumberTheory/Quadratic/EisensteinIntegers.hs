-- |
-- Module:      Math.NumberTheory.EisensteinIntegers
-- Copyright:   (c) 2018 Alexandre Rodrigues Baldé
-- Licence:     MIT
-- Maintainer:  Alexandre Rodrigues Baldé <alexandrer_b@outlook.com>
-- Stability:   Provisional
-- Portability: Non-portable (GHC extensions)
--
-- This module exports functions for manipulating Eisenstein integers, including
-- computing their prime factorisations.
--

{-# LANGUAGE BangPatterns   #-}
{-# LANGUAGE DeriveGeneric  #-}
{-# LANGUAGE RankNTypes     #-}
{-# LANGUAGE TypeFamilies   #-}

module Math.NumberTheory.Quadratic.EisensteinIntegers
  ( EisensteinInteger(..)
  , ω
  , conjugate
  , norm
  , associates
  , ids

  , divideByThree

  -- * Primality functions
  , factorise
  , findPrime
  , isPrime
  , primes
  ) where

import Control.Arrow
import Data.Coerce
import Data.List                                       (mapAccumL, partition)
import Data.Maybe                                      (fromMaybe)
import Data.Ord                                        (comparing)
import GHC.Generics                                    (Generic)

import qualified Math.NumberTheory.Euclidean            as ED
import Math.NumberTheory.Moduli.Sqrt
import qualified Math.NumberTheory.Primes.Factorisation as Factorisation
import Math.NumberTheory.Primes.Types                   (PrimeNat(..))
import qualified Math.NumberTheory.Primes.Sieve         as Sieve
import qualified Math.NumberTheory.Primes.Testing       as Testing
import qualified Math.NumberTheory.UniqueFactorisation  as U
import Math.NumberTheory.Utils                          (mergeBy)
import Math.NumberTheory.Utils.FromIntegral             (integerToNatural, intToWord)

infix 6 :+

-- | An Eisenstein integer is a + bω, where a and b are both integers.
data EisensteinInteger = (:+) { real :: !Integer, imag :: !Integer }
    deriving (Eq, Ord, Generic)

-- | The imaginary unit for Eisenstein integers, where
--
-- > ω == (-1/2) + ((sqrt 3)/2)ι == exp(2*pi*ι/3)
-- and ι is the usual imaginary unit with ι² == -1.
ω :: EisensteinInteger
ω = 0 :+ 1

instance Show EisensteinInteger where
    show (a :+ b)
        | b == 0     = show a
        | a == 0     = s ++ b'
        | otherwise  = show a ++ op ++ b'
        where
            b' = if abs b == 1 then "ω" else show (abs b) ++ "*ω"
            op = if b > 0 then "+" else "-"
            s  = if b > 0 then "" else "-"

instance Num EisensteinInteger where
    (+) (a :+ b) (c :+ d) = (a + c) :+ (b + d)
    (*) (a :+ b) (c :+ d) = (a * c - b * d) :+ (b * (c - d) + a * d)
    abs = fst . absSignum
    negate (a :+ b) = (-a) :+ (-b)
    fromInteger n = n :+ 0
    signum = snd . absSignum

-- | Returns an @EisensteinInteger@'s sign, and its associate in the first
-- sextant.
absSignum :: EisensteinInteger -> (EisensteinInteger, EisensteinInteger)
absSignum z@(a :+ b)
    | a == 0 && b == 0                                  = (z, 0)            -- origin
    | a > b && b >= 0                                   = (z, 1)            -- first sextant: 0 ≤ Arg(η) < π/3
    | b >= a && a > 0                                   = ((-ω) * z, 1 + ω) -- second sextant: π/3 ≤ Arg(η) < 2π/3
    | b > 0 && 0 >= a                                   = ((-1 - ω) * z, ω) -- third sextant: 2π/3 ≤ Arg(η) < π
    | a < b && b <= 0                                   = (- z, -1)         -- fourth sextant: -π < Arg(η) < -2π/3 or Arg(η) = π
    | b <= a && a < 0                                   = (ω * z, -1 - ω)   -- fifth sextant: -2π/3 ≤ Arg(η) < -π/3
    | otherwise                                         = ((1 + ω) * z, -ω) -- sixth sextant: -π/3 ≤ Arg(η) < 0

-- | List of all Eisenstein units, counterclockwise across all sextants,
-- starting with @1@.
ids :: [EisensteinInteger]
ids = take 6 (iterate ((1 + ω) *) 1)

-- | Produce a list of an @EisensteinInteger@'s associates.
associates :: EisensteinInteger -> [EisensteinInteger]
associates e = map (e *) ids

-- | Takes an Eisenstein prime whose norm is of the form @3k + 1@ with @k@
-- a nonnegative integer, and return its primary associate.
-- * Does *not* check for this precondition.
-- * @head@ will fail when supplied a number unsatisfying it.
primary :: EisensteinInteger -> EisensteinInteger
primary = head . filter (\p -> p `ED.mod` 3 == 2) . associates

instance ED.Euclidean EisensteinInteger where
  quotRem = divHelper quot
  divMod  = divHelper div

-- | Function that does most of the underlying work for @divMod@ and
-- @quotRem@, apart from choosing the specific integer division algorithm.
-- This is instead done by the calling function (either @divMod@ which uses
-- @div@, or @quotRem@, which uses @quot@.)
divHelper
    :: (Integer -> Integer -> Integer)
    -> EisensteinInteger
    -> EisensteinInteger
    -> (EisensteinInteger, EisensteinInteger)
divHelper divide g h =
    let nr :+ ni = g * conjugate h
        denom = norm h
        q = divide nr denom :+ divide ni denom
        p = h * q
    in (q, g - p)

-- | Conjugate a Eisenstein integer.
conjugate :: EisensteinInteger -> EisensteinInteger
conjugate (a :+ b) = (a - b) :+ (-b)

-- | The square of the magnitude of a Eisenstein integer.
norm :: EisensteinInteger -> Integer
norm (a :+ b) = a*a - a * b + b*b

-- | Checks if a given @EisensteinInteger@ is prime. @EisensteinInteger@s
-- whose norm is a prime congruent to @0@ or @1@ modulo 3 are prime.
-- See <http://thekeep.eiu.edu/theses/2467 Bandara, Sarada, "An Exposition of the Eisenstein Integers" (2016)>,
-- page 12.
isPrime :: EisensteinInteger -> Bool
isPrime e | e == 0                     = False
          -- Special case, @1 - ω@ is the only Eisenstein prime with norm @3@,
          --  and @abs (1 - ω) = 2 + ω@.
          | a' == 2 && b' == 1         = True
          | b' == 0 && a' `mod` 3 == 2 = Testing.isPrime a'
          | nE `mod` 3 == 1            = Testing.isPrime nE
          | otherwise = False
  where nE       = norm e
        a' :+ b' = abs e

-- | Remove @1 - ω@ factors from an @EisensteinInteger@, and calculate that
-- prime's multiplicity in the number's factorisation.
divideByThree :: EisensteinInteger -> (Int, EisensteinInteger)
divideByThree = go 0
  where
    go :: Int -> EisensteinInteger -> (Int, EisensteinInteger)
    go !n z@(a :+ b) | r1 == 0 && r2 == 0 = go (n + 1) (q1 :+ q2)
                      | otherwise          = (n, abs z)
      where
        -- @(a + a - b) :+ (a + b)@ is @z * (2 :+ 1)@, and @z * (2 :+ 1)/3@
        -- is the same as @z / (1 :+ (-1))@.
        (q1, r1) = divMod (a + a - b) 3
        (q2, r2) = divMod (a + b) 3

-- | Find an Eisenstein integer whose norm is the given prime number
-- in the form @3k + 1@ using a modification of the
-- <http://www.ams.org/journals/mcom/1972-26-120/S0025-5718-1972-0314745-6/S0025-5718-1972-0314745-6.pdf Hermite-Serret algorithm>.
--
-- The maintainer <https://github.com/cartazio/arithmoi/pull/121#issuecomment-415010647 Andrew Lelechenko>
-- derived the following:
-- * Each prime of form @3n+1@ is actually of form @6k+1@.
-- * One has @(z+3k)^2 ≡ z^2 + 6kz + 9k^2 ≡ z^2 + (6k+1)z - z + 9k^2 ≡ z^2 - z + 9k^2 (mod 6k+1)@.
--
-- * The goal is to solve @z^2 - z + 1 ≡ 0 (mod 6k+1)@. One has:
-- @z^2 - z + 9k^2 ≡ 9k^2 - 1 (mod 6k+1)@
-- @(z+3k)^2 ≡ 9k^2-1 (mod 6k+1)@
-- @z+3k = sqrtMod(9k^2-1)@
-- @z = sqrtMod(9k^2-1) - 3k@
--
-- * For example, let @p = 7@, then @k = 1@. Square root of @9*1^2-1 modulo 7@ is @1@.
-- * And @z = 1 - 3*1 = -2 ≡ 5 (mod 7)@.
-- * Truly, @norm (5 :+ 1) = 25 - 5 + 1 = 21 ≡ 0 (mod 7)@.
findPrime :: Integer -> EisensteinInteger
findPrime p = case sqrtsModPrime (9*k*k - 1) (PrimeNat . integerToNatural $ p) of
    []    -> error "findPrime: argument must be prime p = 6k + 1"
    z : _ -> ED.gcd (p :+ 0) ((z - 3 * k) :+ 1)
    where
        k :: Integer
        k = p `div` 6

-- | An infinite list of Eisenstein primes. Uses primes in Z to exhaustively
-- generate all Eisenstein primes in order of ascending magnitude.
-- * Every prime is in the first sextant, so the list contains no associates.
-- * Eisenstein primes from the whole complex plane can be generated by
-- applying @associates@ to each prime in this list.
primes :: [EisensteinInteger]
primes = (2 :+ 1) : mergeBy (comparing norm) l r
  where (leftPrimes, rightPrimes) = partition (\p -> p `mod` 3 == 2) Sieve.primes
        rightPrimes' = filter (\prime -> prime `mod` 3 == 1) $ tail rightPrimes
        l = [p :+ 0 | p <- leftPrimes]
        r = [g | p <- rightPrimes', let x :+ y = findPrime p, g <- [x :+ y, x :+ (x - y)]]

-- | Compute the prime factorisation of a Eisenstein integer. This is unique
-- up to units (+/- 1, +/- ω, +/- ω²).
-- * Unit factors are not included in the result.
-- * All prime factors are primary i.e. @e ≡ 2 (modE 3)@, for an Eisenstein
-- prime factor @e@.
--
-- * This function works by factorising the norm of an Eisenstein integer
-- and then, for each prime factor, finding the Eisenstein prime whose norm
-- is said prime factor with @findPrime@.
--
-- * This is only possible because the norm function of the Euclidean Domain of
-- Eisenstein integers is multiplicative: @norm (e1 * e2) == norm e1 * norm e2@
-- for any two @EisensteinInteger@s @e1, e2@.
--
-- * In the previously mentioned work <http://thekeep.eiu.edu/theses/2467 Bandara, Sarada, "An Exposition of the Eisenstein Integers" (2016)>,
-- in Theorem 8.4 in Chapter 8, a way is given to express any Eisenstein
-- integer @μ@ as @(-1)^a * ω^b * (1 - ω)^c * product [π_i^a_i | i <- [1..N]]@
-- where @a, b, c, a_i@ are nonnegative integers, @N > 1@ is an integer and
-- @π_i@ are primary primes (for a primary Eisenstein prime @p@,
-- @p ≡ 2 (modE 3)@, see @primary@ above).
--
-- * Aplying @norm@ to both sides of Theorem 8.4:
--    @norm μ = norm ((-1)^a * ω^b * (1 - ω)^c * product [ π_i^a_i | i <- [1..N]])@
-- == @norm μ = norm ((-1)^a) * norm (ω^b) * norm ((1 - ω)^c) * norm (product [ π_i^a_i | i <- [1..N]])@
-- == @norm μ = (norm (-1))^a * (norm ω)^b * (norm (1 - ω))^c * product [ norm (π_i^a_i) | i <- [1..N]]@
-- == @norm μ = (norm (-1))^a * (norm ω)^b * (norm (1 - ω))^c * product [ (norm π_i)^a_i) | i <- [1..N]]@
-- == @norm μ = 1^a * 1^b * 3^c * product [ (norm π_i)^a_i) | i <- [1..N]]@
-- == @norm μ = 3^c * product [ (norm π_i)^a_i) | i <- [1..N]]@
-- where @a, b, c, a_i@ are nonnegative integers, and @N > 1@ is an integer.
--
-- * The remainder of the Eisenstein integer factorisation problem is about
-- finding appropriate @[e_i | i <- [1..M]@ such that
-- @(nub . map norm) [e_i | i <- [1..N]] == [π_i | i <- [1..N]]@
-- where @ 1 < N <= M@ are integers, @nub@ removes duplicates and @==@
-- is equality on sets.
--
-- * The reason @M >= N@ is because the prime factors of an Eisenstein integer
-- may include a prime factor and its conjugate, meaning the number may have
-- more Eisenstein prime factors than its norm has integer prime factors.
factorise :: EisensteinInteger -> [(EisensteinInteger, Int)]
factorise g = concat $
              snd $
              mapAccumL go (abs g) (Factorisation.factorise $ norm g)
  where
    go :: EisensteinInteger -> (Integer, Int) -> (EisensteinInteger, [(EisensteinInteger, Int)])
    go z (3, e) | e == n    = (q, [(2 :+ 1, e)])
                | otherwise = error $ "3 is a prime factor of the norm of z\
                                      \ == " ++ show z ++ " with multiplicity\
                                      \ " ++ show e ++ " but (1 - ω) only\
                                      \ divides z " ++ show n ++ "times."
      where
        -- Remove all @1 :+ (-1)@ (which is associated to @2 :+ 1@) factors
        -- from the argument.
        (n, q) = divideByThree z
    go z (p, e) | p `mod` 3 == 2 =
                    let e' = e `quot` 2 in (z `quotI` (p ^ e'), [(p :+ 0, e')])

                -- The @`mod` 3 == 0@ case need not be verified because the
                -- only Eisenstein primes whose norm are a multiple of 3
                -- are @1 - ω@ and its associates, which have already been
                -- removed by the above @go z (3, e)@ pattern match.
                -- This @otherwise@ is mandatorily @`mod` 3 == 1@.
                | otherwise   = (z', filter ((> 0) . snd) [(gp, k), (gp', k')])
      where
        gp@(x :+ y)      = primary $ findPrime p
        -- @gp'@ is @gp@'s conjugate.
        gp'              = primary $ abs $ x :+ (x - y)
        (k, k', z') = divideByPrime gp gp' p e z

        quotI (a :+ b) n = (a `quot` n :+ b `quot` n)

-- | Remove @p@ and @conjugate p@ factors from the argument, where
-- @p@ is an Eisenstein prime.
divideByPrime
    :: EisensteinInteger   -- ^ Eisenstein prime @p@
    -> EisensteinInteger   -- ^ Conjugate of @p@
    -> Integer             -- ^ Precomputed norm of @p@, of form @4k + 1@
    -> Int                 -- ^ Expected number of factors (either @p@ or @conjugate p@)
                           --   in Eisenstein integer @z@
    -> EisensteinInteger   -- ^ Eisenstein integer @z@
    -> ( Int               -- Multiplicity of factor @p@ in @z@
       , Int               -- Multiplicity of factor @conjigate p@ in @z@
       , EisensteinInteger -- Remaining Eisenstein integer
       )
divideByPrime p p' np k = go k 0
    where
        go :: Int -> Int -> EisensteinInteger -> (Int, Int, EisensteinInteger)
        go 0 d z = (d, d, z)
        go c d z | c >= 2, Just z' <- z `quotEvenI` np = go (c - 2) (d + 1) z'
        go c d z = (d + d1, d + d2, z'')
            where
                (d1, z') = go1 c 0 z
                d2 = c - d1
                z'' = head $ drop d2
                    $ iterate (\g -> fromMaybe err $ (g * p) `quotEvenI` np) z'

        go1 :: Int -> Int -> EisensteinInteger -> (Int, EisensteinInteger)
        go1 0 d z = (d, z)
        go1 c d z
            | Just z' <- (z * p') `quotEvenI` np
            = go1 (c - 1) (d + 1) z'
            | otherwise
            = (d, z)

        err = error $ "divideByPrime: malformed arguments" ++ show (p, np, k)

-- | Divide an Eisenstein integer by an even integer.
quotEvenI :: EisensteinInteger -> Integer -> Maybe EisensteinInteger
quotEvenI (x :+ y) n
    | xr == 0 , yr == 0 = Just (xq :+ yq)
    | otherwise         = Nothing
  where
    (xq, xr) = x `quotRem` n
    (yq, yr) = y `quotRem` n

-------------------------------------------------------------------------------

newtype EisensteinPrime = EisensteinPrime { _unEisensteinPrime :: EisensteinInteger }
  deriving (Eq, Show)

instance U.UniqueFactorisation EisensteinInteger where
  type Prime EisensteinInteger = EisensteinPrime
  unPrime = coerce

  factorise 0 = []
  factorise e = map (coerce *** intToWord) $ factorise e

