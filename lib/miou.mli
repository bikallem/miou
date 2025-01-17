(** {1 Miou, a simple scheduler for OCaml 5.}

    Miou is a simple scheduler for OCaml 5 that uses effects. It allows you to
    launch tasks (functions) concurrently and/or in parallel, as well as
    offering your application high availability to system events.

    {2 Basics.}

    {3 Effects.}

    Since OCaml 5, it has been possible to use effects. An effect allows you to
    suspend the execution of a function and {i fall} into a handler which,
    depending on the effect, would perform a specific operation that would
    {i continue} the suspended function with the result of the operation.

    For example, a [Hello: unit Effect.t] effect can suspend using
    {!val:Effect.perform}. A pre-installed {i handler} will then retrieve this
    effect, perform the operation (say, display ["Hello"]), and unsuspend the
    function with the result of the operation (here, [() : unit]).

    {[
      type _ Effect.t += Hello : unit Effect.t

      let handler =
        let retc = Fun.id in
        let exnc = raise in
        let effc
          : type c. c Effect.t -> ((c, 'a) continuation -> 'a) option
          = function
          | Hello ->
            Some (fun k -> continue k (print_endline "Hello"))
          | _ -> None in
        { retc; exnc; effc }

      let my_function () =
        Effect.perform Hello;
        print_endline "World"

      let () = match_with my_function () handler
    ]}

    To go back to familiar OCaml elements, an effect is like an exception in
    that it breaks the execution flow. The "handler" is the [with ...] part of a
    [try ... with ...] in OCaml, and its installation corresponds to the
    [try ...]. Finally, and this is the fundamental difference with exceptions,
    there is the {i continuation} which allows us to return to the point where
    the effect was launched.

    {[
      exception Hello

      let my_function () =
        raise Hello;
        print_endline "World"

      let () =
        try my_function ()
        with Hello k ->
          print_endline "Hello";
          k ()
    ]}

    Miou defines several effects that allow the user to interact with Miou's
    "task manager". Miou's effects manager is installed using {!val:run}. So,
    if you want to use Miou, you should always start with {!val:run}:

    {[
      val my_program : unit -> unit

      let () = Miou.run my_program ()
    ]}

    {3 A task manager.}

    Miou is a task manager. In other words, it manages a list of to-do tasks
    (which you can add to with {!val:call_cc}/{!val:call}) and allows the user
    to manage these tasks. When a task is created, Miou gives the user a
    representation of the task: a promise {!type:t}.

    From this promise, the user can:
    + {!val:await} for the result of the task
    + {!val:cancel} the task

    Here's an example where a list of tasks are initiated and awaited.
    Interaction (task creation and awaiting) with Miou takes place via effects.
    Miou manages the execution order of these tasks and attempts to finish them
    all in order to terminate your program. 

    {[
      let digest filename =
        Miou.call_cc @@ fun () ->
        (filename, Digest.file filename)

      let my_program filenames =
        (* 1) we create a list of tasks *)
        let prms = List.map digest filenames in
        (* 2) Miou manages the execution of these tasks *)
        (* 3) we wait these tasks *)
        let results = List.map Miou.await_exn prms in
        (* 4) we print results *)
        List.iter (fun (filename, hash) ->
          Format.printf "%s: %s\n%!" filename (Digest.to_hex hash))
          results

      let () = Miou.run @@ fun () ->
        my_program ["file01.ml"; "file02.ml"]
    ]}

    Miou suggests a {{!page:scheduler}little exercise} to implement a task
    manager with effects. It explains the role of promises, creation and
    awaiting for a task (it does not, however, describe cancellation).

    {3 Domains.}

    Since OCaml 5, it has been possible to run functions in parallel. These
    functions run on a domain that has its own minor heap - so allocating small
    amounts of data doesn't require synchronization with other domains. Miou
    provides a {i pool} of domains to which the user can assign tasks to run in
    parallel.

    {[
      # let dom = Stdlib.Domain.spawn my_parallel_computation ;;
      # Stdlib.Domain.join dom ;;
    ]}

    For more details on parallelism and garbage collection, we recommend reading
    the OCaml manual.

    Miou prepares the allocation of a certain number of domains in advance.
    These will be waiting for tasks. The {!val:call} function is used to assign
    a new task to one of these domains. The user can specify the number of
    domains Miou can allocate via the [domains] argument to the {!val:run}
    function. We recommend using [Domain.recommended_domain_count () - 1]
    domains.

    {2 Design.}

    After this brief introduction to the basics of Miou (i.e. the use of effects
    and domains and the definition of a task manager), Miou stands out from
    other schedulers through its design, which we'll describe here.

    However, we need to define 3 terms that will be used throughout this
    description:
    - a {i task} is the smallest sequence of programmed instructions that can be
      managed by Miou. In concrete terms, it's an OCaml function.
    - a domain (see {!module:Domain} is a resource representing a processor
      available to execute a task
    - a {i fiber} is a task that will run on a domain in cooperation with other
      tasks

    {3 Preemption and cooperation}

    OCaml offers only a fundamentally cooperative model for executing these
    tasks. Indeed, there are no mechanisms in OCaml to force the suspension of
    a given task. However, a given task can suspend itself in order to cooperate
    with other tasks on a limited resource such as a particular domain.

    Miou offers a way of creating tasks (see {!val:call_cc}) that are more
    precisely called {i fibers}. These fibers must cooperate with each other to
    share the domain on which they run. This means that a fiber should not have
    exclusive domain control when other fibers are waiting to be executed. 

    {[
      # Miou.run @@ fun () ->
        let rec pr str n =
          if n >= 0 then
          begin Miou.yield (); print_endline str; pr str (pred n) end in
        let prm0 = Miou.call_cc @@ fun () -> pr "Hello" 1 in
        let prm1 = Miou.call_cc @@ fun () -> pr "World" 1 in
        Miou.await_exn prm0;
        Miou.await_exn prm1 ;;
      Hello
      World
      Hello
      World
      - : unit = ()
    ]}

    This task cooperation is achieved by {!val:yield}, which interrupts the
    current task to leave the domain to another waiting task.

    The problem with cooperation is that it does not take into account the
    irruption of external elements such as system events. Miou's objective is to
    be able to {i interrupt} your application as soon as these events occur: in
    other words, to {b preempt} the interruption of your tasks when these
    events occur.

    {4 Availability.}

    If it's important for us to interrupt your application as soon as these
    events are received, it's to increase the availability of your application
    to handle these events.

    Let's take the example of a task making a long calculation. If an event such
    as the arrival of a TCP/IP connection were to occur at the same time as the
    calculation, we would consider the latter to be more important than the
    completion of the calculation. So we'd like to interrupt the calculation so
    that your application can handle this event as a priority.

    {[
      let _, _ = Miou.run @@ fun () ->
        let rec server () =
          let socket = accept () in
          let _ = Miou.call (handler socket) in
          server () in
        let prm0 = Miou.call_cc server in
        let prm1 = Miou.call_cc my_long_computation in
        Miou.both prm0 prm1 ;;

      (* [my_long_computation] should have multiple cooperative points to let
         the other task (our [server]) to accept incoming TCP/IP connexions. *)
    ]}

    In other words, your application is "more" available to handle events than
    to perform the calculations requested. This approach becomes interesting for
    services (such as an HTTP server) where the availability to handle such
    events is more important than prioritizing the calculation requested by a
    client.
 
    {4 Cooperation and effects.}

    And therein lies the crux of the problem: how do you preempt in a
    fundamentally cooperative system?

    If we want to be in the best position to manage system events, we need to
    {i increase} the points of cooperation that the fibers can emit. This is how
    Miou came up with a fundamental rule: {b an effect yields}.

    All effects (those defined by Miou as well as those defined by the user)
    reorder task execution. During this reordering, Miou can collect the system
    events that have just occurred. The objective is to do this as often as
    possible!

    {4 Performance and events.}

    At this point, we need to make clear to our future users a crucial choice we
    made for Miou: we prefer a scheduler that's available for system events,
    rather than one that performs well in calculations.

    Indeed, on the cooperation points presented above, Miou will systematically
    ask whether any system events have occurred. However, if your ambition is to
    do nothing but calculations, the latter will be {i "polluted"} by these
    unnecessary points of cooperation. So, by default, Miou is {b less}
    efficient than other schedulers.

    {3 Miou and the system.}

    One of Miou's objectives is to be used in a unikernel. As far as the latter
    is concerned, possible interactions can be very limited. So we decided to
    separate the scheduler ({!module:Miou}) from interactions with the
    underlying system ({!module:Miou_unix} for a UNIX system).

    There is a way to do this:
    + define suspensions that will only be released when certain events occur
    + Miou can collect these events and we can tell it which suspension should
      be "unblocked" according to the collection.

    {4 Suspension points.}

    Miou offers a way of creating what we call a suspension point. This can be
    created from a value {!type:syscall} (with a unique identifier) that the
    user can keep. This suspension point can be "unblocked" if the
    {!type:select} function given to Miou (via {!val:run}) informs it of the
    "continuation" of this suspension.

    Let's take [read()] as an example. This function, which interacts with the
    system, can "block" (for example, if you try to read from a socket). To
    avoid blocking (and leave it to the system), you can ask Miou to suspend
    just beforehand so that it can do other tasks, and inform Miou as soon as
    you know that this [read()] will not block.

    {[
      let global = Hashtbl.create 0x100

      let miou_read fd buf off len =
        let syscall = Miou.make (Fun.const ()) in
        Hashtbl.add global fd syscall;
        Miou.suspend syscall;
        Unix.read fd buf off len
    ]}

    Here, we use a global table to remind us that the file-descriptor we're
    using is associated with a {!type:syscall} we've just created. The next
    objective is to define a {!type:select} function that will observe whether
    the added file-descriptor is ready to be read.

    {4 The [select()] function.}

    Miou lets you inject a function to observe system events. This should appear
    each time tasks are rescheduled, as explained above with regard to
    application availability. This function should return any suspension points
    that can be unblocked.

    {[
      let select ~poll:_ _cancelled_points =
        let fds = Hashtbl.to_seq_keys global |> List.of_seq in
        match Unix.select fds [] [] 0.1 with
        | fds ->
          let continuations = List.map (fun fd ->
            let syscall = Hashtbl.find global fd in
            Miou.continue_with syscall (fun () -> Hashtbl.remove global fd))
            fds in
          continuations

      let run fn =
        let events _domain =
          { Miou.select; interrupt= Fun.const () } in
        Miou.run ~events fn
    ]}

    As you can see, the next step is to produce a {!val:run} function that uses
    our [select]. This is what {!module:Miou_unix} proposes for the example.
    However, there are a number of unresolved issues:
    + in particular, the cancellation of a task and its suspension point
    + or the ability to wait only for system events
    + or the ability to interrupt such an observation

    We recommend reading the chapter on {{!section:system}system events}
    and its tutorial on {!page:sleepers}.

    {3 User task management.}

    Users can manipulate their tasks via their {i promises} (see {!type:t}). A
    promise is an OCaml value representing the task. It can be used to
    {!val:await} for or {!val:cancel} a task. However, certain rules apply to
    its use.

    {4 Rule 1, await for all your tasks.}
    
    It is forbidden to forget your children. The creation of a task necessarily
    implies that the developer {!val:await}s or {!val:cancel}s the task
    afterwards:
    
    {[
      # Miou.run @@ fun () -> Miou.call_cc (Fun.const ()) ;;
      Exception: Miou.Still_has_children.
    ]}
    
    {4 Rule 2, only await for direct children.}
    
    You can only await for your direct children. Transferring a promise to
    another task so that it can await for it is illegal:
    
    {[
      # Miou.run @@ fun () ->
        let p = Miou.call_cc (Fun.const ()) in
        let q = Miou.call_cc (fun () -> Miou.await_exn p) in
        Miou.await_all [ p; q ] |> ignore
      Exception: Miou.Not_a_child.
    ]}

    Task relationship clarifies what is involved in managing tasks and what they
    should transmit to each other. To answer this question, users will have to
    find their own mechanisms ({i mutex}, {i condition}, {i ipc}, etc.) to share
    results between tasks that are not directly related.
    
    {4 Rule 3, a task can only be awaited or cancelled.}
    
    Miou only allows you to await for or cancel a task. It is also impossible to
    detach a task. For more information on this subject, we recommend reading
    the {!section:orphans} section and our following rule:
    {{!section:background}background tasks}.
    
    {4 Rule 4, a task only finishes after its children have finished.}
    
    By extension, as soon as a task is finished, all its children are finished
    too. The same applies to cancellation. If you cancel a task, you also cancel
    its children.

    {4:background Rule 5, background tasks.}

    There is, however, a {i pattern} in which we'd like to put a task aside: in
    other words, forget about it for a while. Miou offers a specific API for
    this pattern, described {{!section:orphans}here}.

    {4 Rule 6, a parallel task will never appear in the main domain.}

    There may be a {i contention} problem if you involve [dom0] in the tasks to
    be run in parallel. There may in fact be a situation where [dom0] is
    awaiting for [dom1], which is awaiting for [dom0].

    Miou does not allow [dom0] to be assigned a parallel task. These assertions
    in the code below are true all the time.

    {[
      # Miou.run @@ fun () ->
        let prm1 = Miou.call @@ fun () ->
          let prm2 = Miou.call @@ fun () ->
            Miou.Domain.self () in
          Miou.await_exn prm2, Miou.Domain.self () in
        let u, v = Miou.await_exn prm1 in
        assert (Miou.Domain.Uid.to_int u <> 0);
        assert (Miou.Domain.Uid.to_int v <> 0);
        assert (u <> v);;
      - : unit = ()
    ]}

    However, you can involve [dom0] in the calculations with {!val:call_cc}.

    {[
      let () = Miou.run @@ fun () ->
        let prm = Miou.call_cc server in
        Miou.parallel server (List.init (Miou.Domain.count ()) (Fun.const ()))
        |> List.iter (function Ok () -> () | Error exn -> raise exn);
        Miou.await_exn prm
    ]}

    The above rule also limits the use of {!val:call} if you only have (or want)
    less than 3 domains. In fact, if you only have one domain, {!val:call}
    cannot launch tasks in parallel. In the event that you only have 2 domains,
    it is possible to launch a task in parallel from [dom0] but it is impossible
    to launch a task in parallel from this [dom1].

    In both cases and in such a situation, an exception is thrown:
    {!exception:No_domain_available}.

    {4 Rule 7, suspension points are local to the domain.}

    A suspension point is local to the domain. This means that only the domain
    in which it was created can unlock it. The Event value is created for each
    domain created by Miou. The unique identifier is also local to the domain.

    {[
      # Miou.run @@ fun () ->
        let fn () = let s = Miou.make (Fun.const ()) in Miou.uid s in
        let uids = Miou.parallel fn (List.init 2 (Fun.const ())) in
        let[@warning "-8"] [ a; b ] = List.map Result.get_ok uids in
        assert (a = b)
      ;;
      - : unit = ()
    ]}

    This code shows that two suspension points are created in two different
    domains and their unique ids are the same.

    The advantage of making suspension points local to domains is that the
    domain is solely responsible for these points and there are no inter-domain
    transfer mechanisms for managing system events. For the example,
    {!module:Domain.DLS} can be used for a table of current events in each
    domain.

    {[
      let get, set =
        let make () = Hashtbl.create () in
        let dom = Stdlib.Domain.DLS.new_key make in
        let get () = Stdlib.Domain.DLS.get dom in
        let set value = Stdlib.Domain.DLS.set dom value in
        get, set

      let miou_read fd buf off len =
        let syscall = Miou.make (Fun.const ()) in
        let tbl = get () in
        Hashtbl.add tbl fd syscall;
        set tbl;
        Miou.suspend syscall;
        Unix.read fd buf off len
    ]}
*)

module State = State
module Queue = Queue

module Ownership : sig
  (** {2 Ownership of resources.}

      {v La propriété, c'est le vol! v}

      Beyond the capitalist idea (even if certain libertarians would qualify the
      notion of private property), it is often useful to associate resources
      with the execution of a task in order to free them as soon as the said
      task is completed (abnormally or not).

      Miou offers such a mechanism where the user can associate a resource ['a]
      with a promise (with {!val:own}). When the task associated with this
      promise is terminated, Miou will check that all the resources have been
      released (using {!val:disown}). If this is not the case, Miou will call
      the "finaliser" specified by the user and fail with an "uncatchable"
      exception: [Resource_leak].

      Note that the user must release these resources {b and} {!val:disown}. In
      fact, {!val:disown} does {b not} call the finaliser (which is only
      executed in an abnormal situation: when the task has raised an exception
      or when a resource has not been released).
  *)

  type t
  (** The type of ownerships. *)

  type uid
  (** The type of unique resource identifiers. *)

  val own : finally:('a -> unit) -> 'a -> t
  (** [own ~finally value] associates the value and this finaliser with the
      current promise. This way, if the current promise fails abnormally, the
      finally function will be called.

      {[
        # let show () = print_endline "Resource released"
        # Miou.run @@ fun () ->
          let p = Miou.call_cc @@ fun () ->
            let _ = Miou.Ownership.own ~finally:show () in
            failwith "p" in
          await_exn p ;;
        Resource released!
        Exception: Failure "p".
      ]}

      {b NOTE}: Finaliser can not perform OCaml's effects. This is because it is
      not "ordered" like a usual task. Using Miou functions (such as
      {!val:await} or {!val:cancel}) in the finaliser will raise an exception:
      {!exception:Effect.Unhandled}.

      It is also important to note that if a task finishes abnormally, as well
      as freeing up the resources of that task, the resources owned by the
      children will also be freed up (hence the uselessness of using await or
      cancel). *)

  val disown : t -> unit
  (** [disown t] informs Miou that you have properly released the resource. If
      the current promise ends well and the user has not [disown] the resource,
      Miou raises the uncatchable exception: [Resource_leak]

      {[
        # let show () = print_endline "Resource released" ;;
        # Miou.run @@ fun () ->
          let p = Miou.call_cc @@ fun () ->
            let _ = Miou.Ownership.own ~finally:show () in
            () in
          await_exn p ;;
        Resource released!
        Exception: Miou.Resource_leak.
      ]}

      Note that even in this situation, Miou calls the finaliser. *)

  val transfer : t -> unit
  (** [transfer t] transfers the ownership to the parent. This can be
      interesting when the resource is locked into a small promise in
      conjunction with others and the parent will make real use of it such as:

      {[
        # exception Timeout
        # Miou.await_one
            [ Miou.call_cc (fun () ->
                let socket = tcpv4 () in
                Miou_unix.connect socket addr;
                Ownership.transfer socket;
                socket)
            ; Miou.call @@ fun () ->
              Miou_unix.sleep 10.; raise Timeout ]
         |> function
         | Ok socket_connected -> ...
         | Error Timeout -> ...
      ]} *)

  val check : t -> unit
  (** [check t] verifies that the given resource [t] is owned by the current
      task. If a task tries to use a resource that does not belong to it,
      {!val:check} will raise an {i uncatchable} exception [Not_owner]. *)

  val uid : t -> uid
  (** [uid resource] returns its unique ID. *)

  val pp : Format.formatter -> uid -> unit
  (** A pretty-printer for {!type:uid}s. *)
end

type 'a t
(** Type of promises. *)

module Domain : sig
  module Uid : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
    val to_int : t -> int
  end

  val self : unit -> Uid.t
  val count : unit -> int
end

module Promise : sig
  module Uid : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  val pp : Format.formatter -> 'a t -> unit
  val uid : 'a t -> Uid.t
end

val self : unit -> Promise.Uid.t * Domain.Uid.t * int
(** [self ()] returns the unique ID of the current promise, the domain which
    runs the current promise and how many resources has the current promise. *)

val stats : unit -> int
(** [stats ()] returns the number of words (in the OCaml sense) reachable from
    the current promise. A promise keeps several pieces of information, such as
    its active children or associated resources. It can be interesting to
    monitor its memory usage. *)

(** {2:orphans Daemon and orphan tasks.}

    The prerogative of absolutely awaiting all of its direct children limits the
    user to considering certain anti-patterns. The best known is the
    {i background} task: it consists of running a task that we would like to
    {i detach} from the main task so that it can continue its life in autonomy.
    For OCaml/[lwt] aficionados, this corresponds to [Lwt.async]:

    {[
      val detach : (unit -> unit t) -> unit
    ]}

    Not that we want to impose an authoritarian family approach between parent
    and children, but the fact remains that these {i orphaned} tasks have
    resources that we need to manage and free-up (even in an abnormal
    situation). We consider detachment to be an {i anti-pattern}, since it
    requires the developer to take particular care (compared to other promises)
    not to 'forget' resources that could lead to memory leaks.

    Instead of letting the developer commit to using a function that might be
    problematic, Miou offers a completely different interface that consists of
    assisting the developer in a coherent (and consistent) approach to
    responding to a particular design that is not all that systematic.

    So a promise can be associated with an {!type:orphans}. The latter will then
    collect the results of the associated promise tasks and give you back the
    promises (via {!val:care}) in a 'non-blocking' mode: applying {!val:await}
    to them will give you the results directly.

    In this way, by creating promises associated with this {!type:orphans}
    value, we can at the same time "clean up" these {i background} tasks, as
    this code shows:

    {[
      let rec clean_up orphans =
        match Miou.care orphans with
        | None -> ()
        | Some prm -> Miou.await_exn prm; clean_up orphans

      let rec server orphans =
        clean_up orphans;
        ignore (Miou.call ~orphans handler);
        server orphans

      let () = Miou.run @@ fun () -> server (Miou.orphans ())
    ]}

    There is a step-by-step {{!page:echo}tutorial} on how to create an echo
    server and how to create a {i daemon} with Miou. *)

type 'a orphans
(** The type of orphan collectors. *)

val orphans : unit -> 'a orphans
(** [orphans ()] makes a new orphan collectors which can used by {!val:call}
    and {!val:call_cc}. *)

val care : 'a orphans -> 'a t option option
(** [care orphans] returns a {i ready-to-await} promise or [Some None]. The user
    must {i consume} the result of the promise with {!val:await}. Otherwise,
    Miou will raises the uncatchable [Still_has_children] exception. If [care]
    returns [None], no children left behind, you can forget the {!type:orphans}
    value safely. *)

(** {2 Launch a promise.} *)

val call_cc :
  ?orphans:'a orphans -> ?give:Ownership.t list -> (unit -> 'a) -> 'a t
(** [call_cc fn] (for Call with Current Continuation) returns a promise
    {!type:t} representing the state of the task given as an argument. The task
    will be carried out {b concurrently} with the other tasks in the current
    domain.

    {b NOTE}: About property and argument [give], property deeds are copied and
    shared between the task initially in possession and the new task. In other
    words, both must {!val:Ownership.disown} before termination. For the
    example, this code doesn't work because the main task ({!val:run}) hasn't
    {!val:Ownership.disown} the resource.

    {[
      # Miou.run @@ fun () ->
        let r = Miou.Ownership.own ~finally:Fun.id () in
        let p = Miou.call ~give:[ r ] @@ fun () -> Miou.Ownership.disown r in
        Miou.await_exn p;;
      Exception: Miou.Resource_leak.
    ]} *)

val call : ?orphans:'a orphans -> ?give:Ownership.t list -> (unit -> 'a) -> 'a t
(** [call fn] returns a promise {!type:t} representing the state of the task
    given as an argument. The task will be run in parallel: the domain used to
    run the task is different from the domain with the promise. This assertion
    is always true:

    {[
      let () = Miou.run @@ fun () ->
        let p = Miou.call @@ fun () ->
          let u = Miou.Domain.self () in
          let q = Miou.call @@ fun () -> Miou.Domain.self () in
          (u, Miou.await_exn q) in
        let u, v = Miou.await_exn p in
        assert (v <> u) ;;
    ]}

    Sequential calls to {!val:call} do not guarantee that different domains are
    always chosen. This code {b may} be true.

    {[
      let () = Miou.run @@ fun () ->
        let p = Miou.call @@ fun () -> Miou.Domain.self () in
        let q = Miou.call @@ fun () -> Miou.Domain.self () in
        let u = Miou.await_exn p in
        let v = Miou.await_exn q in
        assert (u = v);
    ]}

    To ensure that tasks are properly allocated to all domains, you need to use
    {!val:parallel}.

    {b NOTE}: {!val:call} will never run a task on {i dom0} (the main domain).
    Only the other domains can manage tasks in parallel.

    @raise No_domain_available if no domain is available to execute the task in
    parallel or if the function is executed by the only domain available in
    parallel (it is impossible to assign a task to [dom0] from the other
    domains). *)

val parallel : ('a -> 'b) -> 'a list -> ('b, exn) result list
(** [parallel fn lst] is the {i fork-join} model: it is a way of setting up and
    executing parallel tasks, such that execution branches off in parallel at
    designated points in the program, to "join" (merge) at a subsequent point
    and resume sequential execution.

    Let's take the example of a sequential merge-sort:

    {[
      let sort ~compare (arr, lo, hi) =
        if hi - lo >= 2 then begin
          let mi = (lo + hi) / 2 in
          sort ~compare (arr, lo, mi);
          sort ~compare (arr, mi, hi);
          merge ~compare arr lo mi hi
        end
    ]}

    The 2 recursions work on 2 different spaces (from [lo] to [mi] and from [mi]
    to [hi]). We could parallelize their work such that:

    {[
      let sort ~compare (arr, lo, hi) =
        if hi - lo >= 2 then begin
          let mi = (lo + hi) / 2 in
          ignore (Miou.parallel (sort ~compare)
            [ (arr, lo, mi); (arr, mi, hi) ]);
          merge ~compare arr lo mi hi
        end
    ]}

    Note that {!val:parallel} launches tasks ({i fork}) and awaits for them
    ({i join}). Conceptually, this corresponds to a {!val:call} on each elements
    of the given list and a {!val:await_all} on all of them, with tasks
    allocated equally to the domains.

    {b NOTE}: This function will never assign a task to {i dom0} - only the
    other domains can run tasks in parallel. To involve [dom0], it simply has to
    be the one that launches the parallelization and performs the same task
    concurrently.

    {[
      val server : unit -> unit

      let () = Miou.run @@ fun () ->
        let p = Miou.call_cc server in
        Miou.parallel server (List.init (Miou.Domain.count ()) (Fun.const ())
        |> List.iter (function Ok () -> () | Error exn -> raise exn);
        Miou.await_exn p
    ]} *)

(** {2:system System events.}

    Miou does not monitor system events. We arbitrarily leave this event
    monitoring to the user (so that Miou only requires OCaml to run). The
    advantage is that you can inject an event monitor from a specific system
    (such as a unikernel) if you want. However, {!module:Miou_unix} is available
    if you want to do input/output.

    To facilitate the integration of an event monitor, Miou offers an API for
    creating "suspension points" (see {!val:suspend}). In other words, points
    where execution will be blocked for as long as you wish. These points can be
    unblocked as soon as the monitor gives Miou a "continuation" to these points
    with {!val:continue_with}.

    The user must specify a {!type:select} function (via the {!val:run} function
    and the {!type:events} type), which must correspond to system event
    monitoring (probably using [Unix.select]). From these events, the monitor
    can decide which suspension point (thanks to its {!type:uid}) should be
    released. Miou will then call this function for each {i quanta} consumed.
    This gives Miou a high degree of availability to consume and process system
    events.

    {3 Domains, suspension and monitoring.}

    Each domain has its own monitor so that the suspension and its continuation
    given by the monitor is always local to the domain (the domain managing the
    suspension is the only one allowed to execute the continuation). One
    {!type:events} is allocated per domain - it is given on which domain the
    [event] value is assigned. In this way, the values (such as a table of
    active file-descriptors) required to monitor system events need {b not} be
    {i thread-safe}.

    {3 Sleep state.}

    Sometimes, Miou only has suspension points. In other words, only system
    events are required to execute tasks (typically waiting for a TCP/IP
    connection). We say we're in a sleep state. In this case, Miou informs the
    monitor [select] that it can wait indefinitely (with [poll:true]).

    {3 Cancellation.}

    It can happen that a task executed by one domain is cancelled by another
    domain (if the first was created by {!val:call}). This cancellation of a
    task can also mean the cancellation of existing suspension points into the
    task. Miou must therefore be able to {i interrupt} a domain (especially if
    the latter is in a sleep state).

    Thus, the user must have a mechanism for stopping event monitoring, which
    must be given to Miou via the [interrupt] field (see {!type:events}).

    Finally, Miou informs the monitor of any points that have been cancelled, so
    that the associated events can no longer be monitored (this could involve
    cleaning up the table of active file-descritpors).

    {3 Tutorial.}

    To help you understand all these related elements, the distribution offers a
    short tutorial on how to implement functions that can block a given time
    (such as [Unix.sleep]): {!page:sleepers}. *)

type 'a syscall
(** The type of {i syscalls}.

    A syscall is an unique ID and function executed as soon as the suspension
    point is released. This suspension point is created using the {!val:suspend}
    function. ['a] corresponds to the type returned by the function (when the
    suspension point is released by the monitor). *)

type uid = private int [@@immediate]
(** The type of unique IDs of {!type:syscall}s. *)

val make : (unit -> 'a) -> 'a syscall
(** [make return] creates a {i syscall} which permits the user to create a new
    suspension point via {!val:suspend}. *)

val suspend : 'a syscall -> 'a
(** [suspend syscall] creates an user's defined suspension point. Miou will
    keep it internally and only the user is able to {i continue} it via
    {!type:events} (and the [select] field) and a {!type:continue}. *)

val uid : 'a syscall -> uid
(** [uid syscall] returns the unique ID of the syscall.

    {b NOTE}: Uniqueness is local to the domain! This means that 2 domains can
    produce the same {!type:uid}:

    {[
      # Miou.run @@ fun () ->
        let p () =
          let s0 = Miou.make (Fun.const ()) in
          let s1 = Miou.make (Fun.const ()) in
          assert (Miou.uid s0 <> Miou.uid s1);
          Miou.uid s0 in
        Miou.parallel p (List.init 2 (Fun.const ()))
        |> function
        | [ Ok p0s; Ok p1s ] -> assert (p0s = p1s)
        | _ -> assert false 
      ;;
      - : unit = ()
    ]} *)

type continue
(** The type of continuations.

    A continuation is a syscall that has been suspended (with {!val:suspend}) as
    well as a {i pre} function. This is a value that must be given to Miou (via
    [select]) in order to {i unblock} the previously created suspend point. *)

val continue_with : 'a syscall -> (unit -> unit) -> continue
(** [continue_with syscall fn] creates a {!type:continue} value which can be
    used by Miou to unblock the suspension point associated with the given
    syscall. The given function [fn] is pre-processed before Miou executes the
    [syscall]'s function. Any exception raised by the pre-processing function or
    the [syscall]'s function discontinues the suspension point with that
    exception. *)

type select = poll:bool -> uid list -> continue list
type events = { select: select; interrupt: unit -> unit }

val is_pending : 'a syscall -> bool
(** [is_pending syscall] checks the status of the [syscall]'s suspension point.
    A suspension point can be indirectly cancelled (if the user {!val:cancel}s
    the task with the suspension point). The user, in the [events.select]
    function (and {b only} in this function) can check the status of a
    suspension point. If {!val:is_pending} returns [true], then the suspension
    point still exists and the user should give us a function to continue,
    otherwise the user can 'forget' the suspension point safely.

    {b NOTE}: this function can only be executed in the [events.select]
    function. If the user calls it elsewhere, an exception will be raised
    by Miou. *)

(** {2 Await a promise.} *)

val await : 'a t -> ('a, exn) result
(** [await prm] awaits for the task associated with the promise to finish. You
    can assume that after {!val:await}, the task has ended with an exception
    with the [Error] case or normally with the [Ok] case. In the case of an
    abnormal termination (the raising of an exception), the children of the
    promise are cancelled. For instance, this code is valid:

    {[
      # Miou_unix.run @@ fun () ->
        let p = Miou.call_cc @@ fun () ->
          let child_of_p = Miou.call_cc @@ fun () -> Miou_unix.sleep 10. in
          failwith "p";
          Miou.await_exn child_of_p in
        Miou.await p ;;
      - (unit, exn) result = Error (Failure "p")
      # (* [child_of_p] was cancelled and you don't await 10s. *)
    ]}

    Note that you should {b always} await for your children (it's illegal to
    forget your children), as in the example above (even if an exception
    occurs). If a task does not await for its children, an {i uncatchable}
    exception is raised by Miou:

    {[
      # Miou.run @@ fun () ->
        ignore (Miou.call_cc (Fun.const ())) ;;
      Exception: Miou.Still_has_children.
    ]} *)

val await_exn : 'a t -> 'a
(** [await_exn prm] is an alias for {!val:await} which reraises the exception in
    the [Error] case. *)

val await_all : 'a t list -> ('a, exn) result list
(** [await_all prms] awaits for all the tasks linked to the promises given. If
    one of the tasks raises an {i uncatchable} exception, {!val:await_all}
    reraises the said exception. All tasks are awaited for, regardless of
    whether any fail. *)

val await_first : 'a t list -> ('a, exn) result
(** [await_first prms] awaits for a task to finish (by exception or normally)
    and cancels all the others. If several tasks finish "at the same time",
    normally completed tasks are preferred to failed ones. This function can
    be useful for timeouts:

    {[
      # exception Timeout ;;
      # Miou_unix.run @@ fun () ->
        let p0 = Miou.call_cc (Fun.const ()) in
        let p1 = Miou.call_cc @@ fun () -> Miou_unix.sleep 2.; raise Timeout in
        Miou.await_first [ p0; p1 ] ;;
      - : (unit, exn) result = Ok ()
    ]}

    @raise Invalid_argument if the promise list is empty. *)

val await_one : 'a t list -> ('a, exn) result
(** [await_one prms] awaits for a task to finish (by exception or normally).
    Despite {!val:await_first}, {!val:await_one} does {b not} cancel all the
    others. The user must {!val:await} them, otherwise Miou will assume they're
    still active and will raise [Still_has_children].

    {[
      # Miou.run @@ fun () ->
        Miou.await_one
          [ Miou.call_cc (Fun.const 1)
          ; Miou.call_cc (Fun.const 2) ] ;;
      Exception: Miou.Still_has_children
    ]}

    @raise Invalid_argument if the promise list is empty. *)

val both : 'a t -> 'b t -> ('a, exn) result * ('b, exn) result
(** [both prm0 prm1] awaits [prm0] {b and}) [prm1]. It's equivalent to:

    {[
      let both prm0 prm1 =
        let a = Miou.await prm0 in
        let b = Miou.await prm1 in
        (a, b)
    ]} *)

val yield : unit -> unit
(** [yield ()] reschedules tasks and give an opportunity to carry out the tasks
    that have been on hold the longest. For intance:

    {[
      # Miou.run @@ fun () ->
        let p = Miou.call_cc @@ fun () -> print_endline "Hello" in
        print_endline "World";
        Miou.await_exn p ;;
      World
      Hello
      - : unit = ()
      # Miou.run @@ fun () ->
        let p = Miou.call_cc @@ fun () -> print_endline "Hello" in
        Miou.yield ();
        print_endline "World";
        Miou.await_exn p
      Hello
      World
      - : unit = ()
    ]} *)

(** {2 Cancellation.} *)

exception Cancelled
(** Used when a task is cancelled by {!val:cancel}. *)

val cancel : 'a t -> unit
(** [cancel prm] {i asynchronously} cancels the given promise [prm]. Miou
    allows the forgetting of a cancelled promise and the forgetting of its
    children. For instance, this code is valid (despite the second one):

    {[
      # Miou.run @@ fun () ->
        ignore (Miou.cancel (Miou.call (Fun.const ()))) ;;
      - : unit = ()
      # Miou.run @@ fun () ->
        ignore (Miou.call (Fun.const ())) ;;
      Exception: Miou.Still_has_children
    ]}

    Cancellation terminates all the children. After the cancellation, the
    promise and its children all stopped. Resolved children are also cancelled
    (their results are erased). Canceling a task that has already been solved
    changes the state of the task to abnormal termination [Error Cancelled].

    {[
      # Miou.run @@ fun () ->
        let p = Miou.call_cc (Fun.const ()) in
        Miou.await_exn p;
        Miou.cancel p;
        Miou.await_exn p ;;
      Exception: Miou.Cancelled.
    ]}

    This case shows that, even if the task has been resolved internally, the
    cancellation also applies.

    {[
      # Miou.run @@ fun () ->
        let p = Miou.call_cc @@ fun () -> print_endline "Resolved!" in
        Miou.yield ();
        Miou.cancel p;
        Miou.await_exn p ;;
      Resolved!
      Exception: Miou.Cancelled.
    ]}

    Only the creator of a task can {!val:cancel} it (the relationship also
    applies to cancellation, otherwise Miou raises the exception [Not_a_child]).

    {b NOTE}: Cancellation {i asynchronicity} means that other concurrent tasks
    can run while the cancellation is in progress. In fact, in the case of an
    cancellation of a parallel task (see {!val:call}), the cancellation may take
    a certain amount of time (the time it takes for the domains to synchronise)
    which should not affect the opportunity for other concurrent tasks to run.
*)

(** {2 Composition.}

    It is possible to compose Miou with a library that also generates effects.
    The user can compose in 2 ways:
    - simply apply his/her effect manager with its function in Miou
      [Miou.call{,_cc} @@ fun () -> handler fn ()]
    - inform Miou of an effect handler that should comply with the {b {i quanta}
      rule}

    Remember that Miou suspends a task as soon as it emits an effect. The second
    case can be interesting in order to always ensure the availability of the
    application regardless effect handlers. Here's a basic example of how to
    compose.

    {[
      type _ Effect.t += Foo : unit Effect.t

      let handler fn v =
        let open Effect.Deep in
        let retc = Fun.id and exnc = raise in
        let effc : type c. c Effect.t -> ((c, 'a) continuation -> 'b) option =
          function Foo -> Some (fun k -> continue k ())
                 | _ -> None in
        match_with fn v { retc; exnc; effc; }

      let () = Miou.run ~handler:{ Miou.handler } @@ fun () ->
        let prm = Miou.call @@ fun () -> Effect.perform Foo in
        Miou.await_exn prm
    ]}

    The user can also compose several effects managers:

    {[
      # let compose { Miou.handler= a } { Miou.handler= b } =
        { Miou.handler= fun fn v -> (a (b fn)) v } ;;
      val compose : Miou.handler -> Miou.handler -> Miou.handler = <fun>
    ]}

    {b NOTE}: We want to reiterate that such a composition implies that the
    effect will not be executed {i immediately}: the task will be suspended and
    the effect will be produced only as soon as the said task has its execution
    slot. One type of composition therefore becomes impossible if we want the
    production of an effect to produce an immediate action.

    The example below shows that {!val:Effect.perform} suspends and gives [_p]
    the opportunity to execute its task {b before} the [Unhandled] exception is
    raised.

    {[
      # try
          Miou.run @@ fun () ->
          let _p = Miou.call_cc @@ fun () -> print_endline "Hello" in
          Effect.perform Foo
        with Stdlib.Effect.Unhandled Foo -> print_endline "World"
      ;;
      Hello
      World
      - : unit = ()
    ]}
*)

type handler = { handler: 'a 'b. ('a -> 'b) -> 'a -> 'b } [@@unboxed]

exception No_domain_available
(** An exception which can be raised by {!val:call} if no domain is available to
    execute the task in parallel. *)

val run :
     ?quanta:int
  -> ?events:(Domain.Uid.t -> events)
  -> ?g:Random.State.t
  -> ?domains:int
  -> ?handler:handler
  -> (unit -> 'a)
  -> 'a

(**/**)

module Logs : sig
  type level = App | Error | Warning | Info | Debug

  type ('a, 'b) msgf =
       (   ?domain:Stdlib.Domain.id
        -> ?header:string
        -> ('a, Format.formatter, unit, 'b) format4
        -> 'a)
    -> 'b

  val msg : level -> ('a, unit) msgf -> unit
  val debug : ('a, unit) msgf -> unit
  val err : ('a, unit) msgf -> unit
  val warn : ('a, unit) msgf -> unit

  module Make (_ : sig
    val src : string
  end) : sig
    val msg : level -> ('a, unit) msgf -> unit
    val debug : ('a, unit) msgf -> unit
    val err : ('a, unit) msgf -> unit
    val warn : ('a, unit) msgf -> unit
  end
end

module Heapq = Heapq
module Fmt = Fmt
