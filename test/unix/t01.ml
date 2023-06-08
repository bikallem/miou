open Miou
open Miouu

let () = Random.self_init ()

let rec random_float ?not_equal_to max =
  match not_equal_to with
  | None -> Random.float max
  | Some n ->
      if n >= max then invalid_arg "random_float";
      let m = Random.float max in
      if n = m then
        random_float ~not_equal_to:n max
      else
        m

let () =
  let a = random_float 5. in
  let b = random_float ~not_equal_to:a 5. in
  let t0 = Unix.gettimeofday () in
  let () =
    Miouu.run @@ fun () ->
    Prm.await_first_exn
      [
        Prm.call (fun () -> ignore (sleep a))
      ; Prm.call (fun () -> ignore (sleep b))
      ]
  in
  let t1 = Unix.gettimeofday () in
  assert (t1 -. t0 < max a b)