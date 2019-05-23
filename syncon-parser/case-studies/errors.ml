

open Ustring.Op
open Pprint
open Msg

let errorImpossible fi =
  error fi (us"Fatal error. This computation should not be possible to happen!")


let errorCannotInferType fi ty =
  error fi (us"Cannot infer the type of the term. Inferred type " ^.
                 (pprint_ty ty))

let errorCannotDetermineType fi  =
  error fi (us"Cannot determine the type of the term.")

let errorNotFunctionType fi ty =
  error fi (us"The type" ^. pprint_ty ty ^. us"of the expression " ^.
              us"is not a function type.")

let errorVarNotFound fi x =
  error fi (us"Variable '" ^. x ^. us"' cannot be found.")

let errorKindMismatch fi ki1 ki2 =
    error fi (us"The type argument is of kind " ^.
                pprint_kind ki2 ^. us", but a type of kind " ^. pprint_kind ki1 ^.
                us" was expected.")

let errorInferredTypeMismatch fi ty1 tyinf =
  error fi (us"Type mismatch. Inferred  type " ^. pprint_ty tyinf ^.
              us", but found type " ^. pprint_ty ty1 ^. us".")

let errorExpectsUniversal fi ty =
  error fi  (us"Type application expects an universal type, but found " ^.
               pprint_ty ty ^. us".")

let errorUtestExp fi ty1 ty2 =
  error fi  (us"The types " ^. pprint_ty ty1 ^. us" and " ^. pprint_ty ty2 ^.
             us" of the two utest expressions are not equal.")
