/*-------------------------------------------------------------------------
 *
 * planner.c
 *	  set_rel_pathlist hook that offers Index Merge Intersect paths, and
 *	  their conversion into a CustomScan plan.
 *
 * IDENTIFICATION
 *	  src/planner.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/cmptype.h"
#include "access/nbtree.h"
#include "access/sysattr.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_statistic_ext.h"
#include "catalog/pg_type.h"
#include "common/int.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/multibitmapset.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/appendinfo.h"
#include "optimizer/clauses.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/prep.h"
#include "optimizer/restrictinfo.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

#include "leapfrog.h"

/*
 * leapfrog.force scales the costs down rather than zeroing them, so that the
 * cheapest set still wins among the sets.
 */
#define INTERSECT_FORCE_SCALE 1e-12

typedef struct ColumnMatchArg
{
	Index		rti;
	AttrNumber	attno;
	Oid			opfamily;
} ColumnMatchArg;

/* An equality the scan can enforce on one index column, column on the left. */
typedef struct IndexEquality
{
	RestrictInfo *clause;
	Node	   *expr;
	Oid			opno;
	Oid			collation;
	Relids		outer_relids;
} IndexEquality;

/* The hook's state for one relation, shared by every set of streams. */
typedef struct IntersectSearch
{
	PlannerInfo *root;
	RelOptInfo *rel;
	Index		rti;
	RangeTblEntry *rte;
	SortColumn	sort;
	PathKey    *pathkey;
	IndexCandidate *candidates;
	int			ncandidates;
	double		ndistinct;		/* -1 until looked up */
	bool		statistics_apply;	/* extended statistics on the conditions */
} IntersectSearch;

/* The cheapest and the quickest set seen with one parameterization. */
typedef struct SetChoice
{
	Relids		required_outer;
	CustomPath *best;
	CustomPath *quickest;
} SetChoice;

/*
 * The path of one set of streams.  The keys and predicates stay in
 * custom_private, the only part reparameterize_path_by_child can translate.
 */
typedef struct IntersectPath
{
	CustomPath	cpath;
	IntersectPlanInfo *info;
} IntersectPath;

static set_rel_pathlist_hook_type prev_set_rel_pathlist_hook = NULL;

static void intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel,
									   Index rti, RangeTblEntry *rte);
static Plan *intersect_plan_path(PlannerInfo *root, RelOptInfo *rel,
								 CustomPath *best_path, List *tlist,
								 List *clauses, List *custom_plans);
static List *intersect_reparameterize(PlannerInfo *root, List *custom_private,
									  RelOptInfo *child_rel);

static const CustomPathMethods intersect_path_methods = {
	.CustomName = INTERSECT_NAME,
	.PlanCustomPath = intersect_plan_path,
	.ReparameterizeCustomPathByChild = intersect_reparameterize,
};

static Const *
make_oid_const(Oid value)
{
	return makeConst(OIDOID, -1, InvalidOid, sizeof(Oid),
					 ObjectIdGetDatum(value), false, true);
}

static Const *
make_int4_const(int32 value)
{
	return makeConst(INT4OID, -1, InvalidOid, sizeof(int32),
					 Int32GetDatum(value), false, true);
}

static Const *
make_float8_const(double value)
{
	return makeConst(FLOAT8OID, -1, InvalidOid, sizeof(float8),
					 Float8GetDatum(value), false, FLOAT8PASSBYVAL);
}

/*
 * match_column_var
 *		The Var of column attno the node stands for, or NULL.  RelabelType is
 *		looked through: a varchar or domain column appears relabeled.
 */
static Var *
match_column_var(Node *node, Index rti, AttrNumber attno)
{
	Var		   *var;

	while (node && IsA(node, RelabelType))
		node = (Node *) ((RelabelType *) node)->arg;

	if (node == NULL || !IsA(node, Var))
		return NULL;

	var = (Var *) node;
	if (var->varno != rti || var->varattno != attno || var->varlevelsup != 0)
		return NULL;

	return var;
}

static bool
is_column_var(Node *node, Index rti, AttrNumber attno)
{
	return match_column_var(node, rti, attno) != NULL;
}

/*
 * match_index_equality
 *		Is the clause "col = y", usable as an Index Cond on key column col?
 *		The index collation must match the clause's, and the clause must be
 *		safe before the row security quals: a scan key sees hidden rows too.
 */
static bool
match_index_equality(RestrictInfo *rinfo, Index rti, IndexOptInfo *index,
					 int col, IndexEquality *equality)
{
	AttrNumber	attno = index->indexkeys[col];
	OpExpr	   *op;
	Node	   *left;
	Node	   *right;
	Oid			opno;

	if (rinfo->pseudoconstant || !IsA(rinfo->clause, OpExpr) ||
		!restriction_is_securely_promotable(rinfo, index->rel))
		return false;

	op = (OpExpr *) rinfo->clause;
	if (list_length(op->args) != 2 || op->opresulttype != BOOLOID)
		return false;

	left = linitial(op->args);
	right = lsecond(op->args);
	opno = op->opno;

	if (!is_column_var(left, rti, attno))
	{
		Node	   *tmp = left;

		left = right;
		right = tmp;
		opno = get_commutator(opno);
		if (!OidIsValid(opno))
			return false;
	}

	if (!is_column_var(left, rti, attno) ||
		get_op_opfamily_strategy(opno, index->opfamily[col]) !=
		BTEqualStrategyNumber)
		return false;

	if (OidIsValid(index->indexcollations[col]) &&
		index->indexcollations[col] != op->inputcollid)
		return false;

	equality->clause = rinfo;
	equality->expr = right;
	equality->opno = opno;
	equality->collation = op->inputcollid;
	equality->outer_relids = NULL;

	return true;
}

/* ec_matches_callback_type for the column of a ColumnMatchArg. */
static bool
ec_member_is_column(PlannerInfo *root, RelOptInfo *rel, EquivalenceClass *ec,
					EquivalenceMember *em, void *arg)
{
	ColumnMatchArg *column = (ColumnMatchArg *) arg;

	if (!list_member_oid(ec->ec_opfamilies, column->opfamily))
		return false;

	return is_column_var((Node *) em->em_expr, column->rti, column->attno);
}

/*
 * find_join_equality
 *		Pick "col = value" from join clauses, the value a non-volatile
 *		expression of other relations only (nestloop parameters).
 */
static bool
find_join_equality(PlannerInfo *root, List *clauses, RelOptInfo *rel,
				   Index rti, IndexOptInfo *index, int col,
				   IndexEquality *equality)
{
	ListCell   *lc;

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
		Relids		outer_relids;

		if (!match_index_equality(rinfo, rti, index, col, equality))
			continue;

		outer_relids = pull_varnos(root, equality->expr);
		if (!bms_is_empty(outer_relids) &&
			!bms_overlap(outer_relids, rel->relids) &&
			!contain_volatile_functions(equality->expr) &&
			join_clause_is_movable_to(rinfo, rel))
		{
			equality->outer_relids = outer_relids;
			return true;
		}
	}

	return false;
}

/*
 * find_equality_clause
 *		Look for "col = value" among the restrictions of rel, its join clauses
 *		and the equalities implied by equivalence classes (a mergejoinable join
 *		clause lives there, not in joininfo).
 */
static bool
find_equality_clause(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 IndexOptInfo *index, int col, IndexEquality *equality)
{
	ListCell   *lc;
	ColumnMatchArg arg;

	foreach(lc, rel->baserestrictinfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);

		if (!match_index_equality(rinfo, rti, index, col, equality))
			continue;

		/* evaluated once per (re)scan; a NULL constant matches no row */
		if (IsA(equality->expr, Const))
		{
			if (!((Const *) equality->expr)->constisnull)
				return true;
		}
		else if (!contain_var_clause(equality->expr) &&
				 !contain_volatile_functions(equality->expr))
			return true;
	}

	if (find_join_equality(root, rel->joininfo, rel, rti, index, col,
						   equality))
		return true;

	if (!rel->has_eclass_joins)
		return false;

	arg.rti = rti;
	arg.attno = index->indexkeys[col];
	arg.opfamily = index->opfamily[col];

	return find_join_equality(root,
							  generate_implied_equalities_for_column(root, rel,
																	 ec_member_is_column,
																	 &arg,
																	 rel->lateral_referencers),
							  rel, rti, index, col, equality);
}

/*
 * pathkey_is_column
 *		Is the pathkey a sort on column attno of relation rti?  A member nulled
 *		by an outer join does not count; a partition's column is a child
 *		member, which only the iterator shows.
 */
static bool
pathkey_is_column(PathKey *pathkey, RelOptInfo *rel, Index rti,
				  AttrNumber attno)
{
	EquivalenceMemberIterator it;
	EquivalenceMember *em;

	setup_eclass_member_iterator(&it, pathkey->pk_eclass, rel->relids);
	while ((em = eclass_member_iterator_next(&it)) != NULL)
	{
		Var		   *var = match_column_var((Node *) em->em_expr, rti, attno);

		if (var != NULL && var->varnullingrels == NULL)
			return true;
	}

	return false;
}

/*
 * is_notnull_column
 *		Can the node leave the sort column's NULLs out?  notnullattnums, not
 *		attnotnull (NOT VALID sets that with NULLs still there), or a strict
 *		restriction; not a join clause, as an unparameterized path is offered.
 */
static bool
is_notnull_column(RelOptInfo *rel, Index rti, AttrNumber attno)
{
	List	   *clauses;

	if (bms_is_member(attno, rel->notnullattnums))
		return true;

	clauses = extract_actual_clauses(rel->baserestrictinfo, false);
	return mbms_is_member(rti, attno - FirstLowInvalidHeapAttributeNumber,
						  find_nonnullable_vars((Node *) clauses));
}

/* Does the btree order duplicate keys by heap TID (version 4 format)? */
static bool
is_heapkeyspace(IndexCandidate *candidate)
{
	if (candidate->heapkeyspace < 0)
	{
		Relation	index = index_open(candidate->index->indexoid,
									   AccessShareLock);
		bool		heapkeyspace;
		bool		allequalimage;

		_bt_metaversion(index, &heapkeyspace, &allequalimage);
		index_close(index, AccessShareLock);
		candidate->heapkeyspace = heapkeyspace ? 1 : 0;
	}

	return candidate->heapkeyspace == 1;
}

static bool
is_backward_stream(IndexOptInfo *index, int pos, SortColumn *sort)
{
	return index->reverse_sort[pos] != sort->descending;
}

/*
 * is_usable_btree
 *		A btree whose column at pos sorts like the query's sort key, NULLs
 *		placement included unless the node leaves them out.  is_heapkeyspace
 *		is checked later: it opens the index.
 */
static bool
is_usable_btree(IndexOptInfo *index, int pos, SortColumn *sort)
{
	return index->relam == BTREE_AM_OID &&
		!index->hypothetical &&
		(index->indpred == NIL || index->predOK) &&
		index->sortopfamily != NULL &&
		index->sortopfamily[pos] == sort->opfamily &&
		index->opcintype[pos] == sort->type &&
		index->indexcollations[pos] == sort->collation &&
		(sort->notnull ||
		 (is_backward_stream(index, pos, sort) ? !index->nulls_first[pos] :
		  index->nulls_first[pos]) == sort->nulls_first);
}

/*
 * find_index_candidate
 *		Can the index produce the sort column in order?
 */
static bool
find_index_candidate(IntersectSearch *search, IndexOptInfo *index,
					 IndexCandidate *candidate)
{
	int			sortpos = -1;

	candidate->index = index;
	candidate->clauses = NIL;
	candidate->exprs = NIL;
	candidate->operators = NIL;
	candidate->collations = NIL;
	candidate->required_outer = NULL;
	candidate->heapkeyspace = -1;
	candidate->range_known = -1;
	candidate->correlation = -2.0;
	candidate->holds_nulls = -1;
	candidate->group_probes = NIL;

	for (int i = 0; i < index->nkeycolumns; i++)
	{
		if (index->indexkeys[i] == search->sort.attno)
		{
			sortpos = i;
			break;
		}
	}
	candidate->sortpos = sortpos;

	if (sortpos < 0 || !is_usable_btree(index, sortpos, &search->sort))
		return false;

	for (int i = 0; i < sortpos; i++)
	{
		IndexEquality equality;

		/* an expression column has no attno to compare with */
		if (index->indexkeys[i] == 0 ||
			!find_equality_clause(search->root, search->rel, search->rti,
								  index, i, &equality))
			return false;

		candidate->clauses = lappend(candidate->clauses, equality.clause);
		candidate->exprs = lappend(candidate->exprs, equality.expr);
		candidate->operators = lappend_oid(candidate->operators, equality.opno);
		candidate->collations = lappend_oid(candidate->collations,
											equality.collation);
		candidate->required_outer = bms_add_members(candidate->required_outer,
													equality.outer_relids);
	}

	candidate->backward = is_backward_stream(index, sortpos, &search->sort);
	candidate->entries = lf_index_entries(search->root, search->rti, candidate);

	return true;
}

static bool
equality_column_in_set(IndexCandidate **streams, int nstreams,
					   IndexCandidate *skip, AttrNumber attno)
{
	for (int i = 0; i < nstreams; i++)
	{
		IndexOptInfo *index = streams[i]->index;

		if (streams[i] == skip)
			continue;
		for (int j = 0; j < streams[i]->sortpos; j++)
		{
			if (index->indexkeys[j] == attno)
				return true;
		}
	}

	return false;
}

/*
 * adds_restriction
 *		Does the candidate restrict the rows beyond the set's other streams:
 *		an equality column they lack, or a predicate they do not imply?
 *		candidate may itself be one of streams.
 */
static bool
adds_restriction(IndexCandidate **streams, int nstreams,
				 IndexCandidate *candidate)
{
	IndexOptInfo *index = candidate->index;

	for (int i = 0; i < candidate->sortpos; i++)
	{
		if (!equality_column_in_set(streams, nstreams, candidate,
									index->indexkeys[i]))
			return true;
	}

	if (index->indpred != NIL)
	{
		List	   *enforced = NIL;

		for (int i = 0; i < nstreams; i++)
		{
			if (streams[i] == candidate)
				continue;
			enforced = list_concat_copy(enforced, streams[i]->clauses);
			enforced = list_concat_copy(enforced, streams[i]->index->indpred);
		}
		if (!predicate_implied_by(index->indpred, enforced, false))
			return true;
	}

	return false;
}

/*
 * is_inner_candidate
 *		Can the index join the set, with every stream of the result still
 *		adding a restriction of its own?
 */
static bool
is_inner_candidate(IndexCandidate **streams, int nstreams,
				   IndexCandidate *candidate)
{
	IndexCandidate *set[INTERSECT_MAX_STREAMS];

	if (!candidate->usable)
		return false;
	for (int i = 0; i < nstreams; i++)
	{
		if (streams[i] == candidate)
			return false;
		set[i] = streams[i];
	}
	set[nstreams] = candidate;

	for (int i = 0; i <= nstreams; i++)
	{
		if (!adds_restriction(set, nstreams + 1, set[i]))
			return false;
	}

	return true;
}

/* Relids a set of these streams, and extra when not NULL, would require. */
static Relids
set_required_outer(IntersectSearch *search, IndexCandidate **streams,
				   int nstreams, IndexCandidate *extra)
{
	Relids		required_outer = NULL;

	for (int i = 0; i < nstreams; i++)
		required_outer = bms_add_members(required_outer,
										 streams[i]->required_outer);
	if (extra != NULL)
		required_outer = bms_add_members(required_outer, extra->required_outer);
	return bms_add_members(required_outer, search->rel->lateral_relids);
}

/*
 * build_intersect_path
 *		Build and cost the path for one set of streams, streams[0] the outer
 *		one; NULL when the set cannot be used.
 */
static CustomPath *
build_intersect_path(IntersectSearch *search, IndexCandidate **streams,
					 int nstreams, Cost *fetch_cost, double correlation)
{
	PlannerInfo *root = search->root;
	RelOptInfo *rel = search->rel;
	IntersectPath *ipath;
	CustomPath *cpath;
	IntersectPlanInfo *info;
	List	   *exprs = NIL;
	ParamPathInfo *param_info = NULL;
	Relids		required_outer;
	double		group_bytes = 0;
	double		reads[INTERSECT_MAX_STREAMS];
	int			ranks[INTERSECT_MAX_STREAMS];

	if (search->ndistinct < 0)
		search->ndistinct = lf_sortcol_ndistinct(root, rel, search->rti,
												 search->sort.attno);

	/* the executor enforces work_mem itself, so force may ignore this */
	for (int i = 1; i < nstreams; i++)
		group_bytes += Max(1.0, streams[i]->entries / search->ndistinct) *
			sizeof(ItemPointerData);
	if (!intersect_force && group_bytes > work_mem * 1024.0)
		return NULL;

	/* duplicates must be ordered by TID in every stream */
	for (int i = 0; i < nstreams; i++)
	{
		if (!is_heapkeyspace(streams[i]))
			return NULL;
	}

	required_outer = set_required_outer(search, streams, nstreams, NULL);
	if (!bms_is_empty(required_outer))
		param_info = get_baserel_parampathinfo(root, rel, required_outer);

	ipath = (IntersectPath *) newNode(sizeof(IntersectPath), T_CustomPath);
	cpath = &ipath->cpath;

	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = rel;
	cpath->path.pathtarget = rel->reltarget;
	cpath->path.param_info = param_info;
	cpath->path.parallel_aware = false;
	cpath->path.parallel_safe = false;
	cpath->path.parallel_workers = 0;
	cpath->path.rows = param_info ? param_info->ppi_rows : rel->rows;
	cpath->path.pathkeys = list_make1(search->pathkey);
	cpath->flags = 0;
	cpath->methods = &intersect_path_methods;

	lf_cost_intersect_path(cpath, root, search->rte, &search->sort,
						   streams, nstreams, search->ndistinct, correlation,
						   reads, ranks, fetch_cost);
	lf_trace.sets++;

	info = palloc0(IntersectPlanInfoSize(nstreams));
	info->descending = search->sort.descending;
	info->sort_type = search->sort.type;
	info->sort_opfamily = search->sort.opfamily;
	info->sort_collation = search->sort.collation;
	info->nulls_first = search->sort.nulls_first;
	info->notnull = search->sort.notnull;
	info->nstreams = nstreams;
	for (int i = 0; i < nstreams; i++)
	{
		IntersectStreamInfo *stream = &info->streams[i];

		stream->indexoid = streams[i]->index->indexoid;
		stream->sortpos = streams[i]->sortpos;
		stream->reads = reads[i];
		stream->operators = list_copy(streams[i]->operators);
		stream->collations = list_copy(streams[i]->collations);
		stream->backward = streams[i]->backward;
		stream->rank = ranks[i];
		exprs = lappend(exprs, copyObject(streams[i]->exprs));
		exprs = lappend(exprs,
						i > 0 ? copyObject(streams[i]->index->indpred) : NIL);
	}
	ipath->info = info;
	cpath->custom_private = exprs;

	return cpath;
}

/* add_path, with the costs scaled down under leapfrog.force. */
static void
add_intersect_path(RelOptInfo *rel, CustomPath *cpath)
{
	if (intersect_force)
	{
		cpath->path.startup_cost *= INTERSECT_FORCE_SCALE;
		cpath->path.total_cost *= INTERSECT_FORCE_SCALE;
	}

	lf_trace.paths++;
	add_path(rel, &cpath->path);
}

/* Fewest entries first; the OID makes it deterministic. */
static int
candidate_entries_cmp(const void *a, const void *b)
{
	const IndexCandidate *ca = (const IndexCandidate *) a;
	const IndexCandidate *cb = (const IndexCandidate *) b;

	if (ca->entries != cb->entries)
		return ca->entries < cb->entries ? -1 : 1;
	return pg_cmp_u32(ca->index->indexoid, cb->index->indexoid);
}

/*
 * build_set_path
 *		Build the path of a set, the densest stream without a predicate as
 *		the outer one (docs/design.md).
 */
static CustomPath *
build_set_path(IntersectSearch *search, IndexCandidate **streams, int nstreams,
			   Cost *fetch_cost)
{
	IndexCandidate *ordered[INTERSECT_MAX_STREAMS];
	int			outer = 0;

	for (int i = 0; i < nstreams; i++)
	{
		if (streams[i]->index->indpred == NIL)
			outer = i;
		ordered[i] = streams[i];
	}
	ordered[0] = streams[outer];
	ordered[outer] = streams[0];

	if (ordered[0]->correlation < -1.5)
		ordered[0]->correlation = lf_outer_index_correlation(search->root,
															 search->rti,
															 ordered[0]->index);

	return build_intersect_path(search, ordered, nstreams, fetch_cost,
								ordered[0]->correlation);
}

/* Does an MCV or dependencies object cover two condition columns? */
static bool
statistics_cover_conditions(IntersectSearch *search)
{
	Bitmapset  *attnos = NULL;
	ListCell   *lc;

	if (search->rel->statlist == NIL)
		return false;

	for (int i = 0; i < search->ncandidates; i++)
	{
		IndexCandidate *candidate = &search->candidates[i];

		foreach(lc, candidate->clauses)
			pull_varattnos((Node *) lfirst_node(RestrictInfo, lc)->clause,
						   search->rti, &attnos);
		pull_varattnos((Node *) candidate->index->indpred, search->rti,
					   &attnos);
	}

	foreach(lc, search->rel->statlist)
	{
		StatisticExtInfo *stat = lfirst_node(StatisticExtInfo, lc);
		int			covered = 0;
		int			key = -1;

		if (stat->kind != STATS_EXT_MCV &&
			stat->kind != STATS_EXT_DEPENDENCIES)
			continue;
		while ((key = bms_next_member(stat->keys, key)) >= 0)
		{
			if (bms_is_member(key - FirstLowInvalidHeapAttributeNumber, attnos))
				covered++;
		}
		if (covered >= 2)
			return true;
	}

	return false;
}

static SetChoice *
find_choice(List *choices, Relids required_outer)
{
	ListCell   *lc;

	foreach(lc, choices)
	{
		SetChoice  *choice = lfirst(lc);

		if (bms_equal(choice->required_outer, required_outer))
			return choice;
	}
	return NULL;
}

/*
 * consider_set
 *		Keep the cheapest and the quickest set of each parameterization:
 *		add_path keeps paths of different parameterizations side by side.
 */
static void
consider_set(List **choices, CustomPath *cpath)
{
	Relids		required_outer = PATH_REQ_OUTER(&cpath->path);
	SetChoice  *choice = find_choice(*choices, required_outer);

	if (choice == NULL)
	{
		choice = palloc0(sizeof(SetChoice));
		choice->required_outer = required_outer;
		*choices = lappend(*choices, choice);
	}
	if (choice->best == NULL ||
		cpath->path.total_cost < choice->best->path.total_cost)
		choice->best = cpath;
	if (choice->quickest == NULL ||
		cpath->path.startup_cost < choice->quickest->path.startup_cost)
		choice->quickest = cpath;
}

/*
 * search_intersection
 *		One pass over the candidates, offering the cheapest set seen and the
 *		one quickest to its first row; see docs/design.md.  plain_only leaves
 *		out the candidates that need a parameter.
 */
static void
search_intersection(IntersectSearch *search, bool plain_only)
{
	IndexCandidate *streams[INTERSECT_MAX_STREAMS];
	int			nstreams = 0;
	List	   *choices = NIL;
	Cost		fetch_cost = 0;
	Cost		last_cost = 0;
	ListCell   *lc;

	for (int j = 0; j < search->ncandidates &&
		 nstreams < intersect_max_streams; j++)
	{
		IndexCandidate *candidate = &search->candidates[j];
		CustomPath *cpath;
		SetChoice  *choice;

		if (plain_only && !bms_is_empty(candidate->required_outer))
			continue;
		if (nstreams == 0)
		{
			streams[nstreams++] = candidate;
			continue;
		}
		if (!is_inner_candidate(streams, nstreams, candidate))
			continue;

		/* a stream saves at most the heap fetches: prune without probing */
		choice = find_choice(choices, set_required_outer(search, streams,
														 nstreams, candidate));
		if (choice != NULL &&
			last_cost - fetch_cost + lf_stream_min_cost(candidate->index) >=
			choice->best->path.total_cost)
		{
			lf_trace.pruned++;
			continue;
		}

		streams[nstreams] = candidate;
		cpath = build_set_path(search, streams, nstreams + 1, &fetch_cost);
		if (cpath == NULL)
			continue;
		nstreams++;
		last_cost = cpath->path.total_cost;

		if (nstreams >= intersect_min_streams)
			consider_set(&choices, cpath);
	}

	/* correlated conditions: also pair the first stream with each other */
	if (nstreams > 0 && intersect_min_streams <= 2 && search->statistics_apply)
	{
		for (int j = 0; j < search->ncandidates; j++)
		{
			IndexCandidate *candidate = &search->candidates[j];
			IndexCandidate *pair[2];
			Cost		pair_fetch_cost;
			CustomPath *cpath;

			if (plain_only ? !bms_is_empty(candidate->required_outer) :
				bms_is_empty(streams[0]->required_outer) &&
				bms_is_empty(candidate->required_outer))
				continue;
			if (nstreams > 1 && candidate == streams[1])
				continue;
			if (!is_inner_candidate(streams, 1, candidate))
				continue;

			pair[0] = streams[0];
			pair[1] = candidate;
			cpath = build_set_path(search, pair, 2, &pair_fetch_cost);
			if (cpath != NULL)
				consider_set(&choices, cpath);
		}
	}

	foreach(lc, choices)
	{
		SetChoice  *choice = lfirst(lc);

		if (choice->quickest != choice->best)
			add_intersect_path(search->rel, choice->quickest);
		add_intersect_path(search->rel, choice->best);
	}
	list_free_deep(choices);
}

/*
 * intersect_set_rel_pathlist
 *		set_rel_pathlist_hook.  A partition is a relation of its own here.
 */
static void
intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti,
						   RangeTblEntry *rte)
{
	IntersectSearch search;
	EquivalenceMemberIterator it;
	EquivalenceMember *em;
	ListCell   *lc;

	if (prev_set_rel_pathlist_hook)
		prev_set_rel_pathlist_hook(root, rel, rti, rte);

	/* a sampled relation is read through its Sample Scan only */
	if (!intersect_enabled || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION || rte->tablesample != NULL ||
		!IS_SIMPLE_REL(rel) || root->query_pathkeys == NIL ||
		IS_DUMMY_REL(rel) || rel->indexlist == NIL)
		return;

	search.root = root;
	search.rel = rel;
	search.rti = rti;
	search.rte = rte;
	search.sort.attno = InvalidAttrNumber;
	search.ndistinct = -1.0;

	search.pathkey = linitial_node(PathKey, root->query_pathkeys);
	setup_eclass_member_iterator(&it, search.pathkey->pk_eclass, rel->relids);
	while ((em = eclass_member_iterator_next(&it)) != NULL)
	{
		Node	   *expr = (Node *) em->em_expr;
		AttrNumber	attno;

		while (IsA(expr, RelabelType))
			expr = (Node *) ((RelabelType *) expr)->arg;
		if (!IsA(expr, Var))
			continue;
		attno = ((Var *) expr)->varattno;
		if (attno > 0 && pathkey_is_column(search.pathkey, rel, rti, attno))
		{
			search.sort.attno = attno;
			search.sort.type = em->em_datatype;
			search.sort.opfamily = search.pathkey->pk_opfamily;
			search.sort.collation = search.pathkey->pk_eclass->ec_collation;
			search.sort.descending = search.pathkey->pk_cmptype == COMPARE_GT;
			search.sort.nulls_first = search.pathkey->pk_nulls_first;
			search.sort.notnull = is_notnull_column(rel, rti, attno);
			search.sort.null_frac = -1.0;
			search.sort.range_ssup_ready = false;
			search.sort.stats = NULL;
			break;
		}
	}

	if (search.sort.attno == InvalidAttrNumber)
		return;

	search.candidates = palloc(list_length(rel->indexlist) *
							   sizeof(IndexCandidate));
	search.ncandidates = 0;
	memset(&lf_trace, 0, sizeof(lf_trace));
	foreach(lc, rel->indexlist)
	{
		IndexCandidate *candidate = &search.candidates[search.ncandidates];

		candidate->usable = find_index_candidate(&search,
												 lfirst_node(IndexOptInfo, lc),
												 candidate);
		if (candidate->usable)
			search.ncandidates++;
	}

	qsort(search.candidates, search.ncandidates, sizeof(IndexCandidate),
		  candidate_entries_cmp);
	search.statistics_apply = statistics_cover_conditions(&search);

	search_intersection(&search, true);
	for (int i = 0; i < search.ncandidates; i++)
	{
		if (!bms_is_empty(search.candidates[i].required_outer))
		{
			search_intersection(&search, false);
			break;
		}
	}

	lf_trace.candidates = search.ncandidates;
	if (intersect_trace_planner)
		elog(NOTICE,
			 "leapfrog planner: %d candidates, %d sets, %d range scans, %d statistics reads, %d range fallbacks, %d correlations, %d pruned, %d paths",
			 lf_trace.candidates, lf_trace.sets, lf_trace.range_scans,
			 lf_trace.stat_loads, lf_trace.range_fallbacks,
			 lf_trace.correlations, lf_trace.pruned, lf_trace.paths);

	pfree(search.candidates);
}

static bool
is_candidate_equality(RestrictInfo *rinfo, Index rti, IndexOptInfo *index,
					  List *exprs)
{
	int			i = 0;
	ListCell   *lc;

	foreach(lc, exprs)
	{
		IndexEquality equality;

		if (match_index_equality(rinfo, rti, index, i, &equality) &&
			equal(equality.expr, lfirst(lc)))
			return true;
		i++;
	}

	return false;
}

static IndexOptInfo *
find_index_info(RelOptInfo *rel, Oid indexoid)
{
	ListCell   *lc;

	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, lc);

		if (index->indexoid == indexoid)
			return index;
	}

	elog(ERROR, "index %u is not an index of the relation", indexoid);
	return NULL;				/* keep compiler quiet */
}

/*
 * form_plan_info
 *		Write the plan info into custom_private and, for the expressions that
 *		setrefs.c must fix, custom_exprs; lf_deform_plan_info reads it back.
 */
static void
form_plan_info(IntersectPlanInfo *info, CustomScan *cscan)
{
	List	   *private = NIL;
	List	   *exprs = NIL;

	private = lappend(private, makeBoolConst(info->descending, false));
	private = lappend(private, make_oid_const(info->sort_type));
	private = lappend(private, make_oid_const(info->sort_opfamily));
	private = lappend(private, make_oid_const(info->sort_collation));
	private = lappend(private, makeBoolConst(info->nulls_first, false));
	private = lappend(private, makeBoolConst(info->notnull, false));
	private = lappend(private, make_int4_const(info->nstreams));
	for (int i = 0; i < info->nstreams; i++)
	{
		IntersectStreamInfo *stream = &info->streams[i];

		private = lappend(private, make_oid_const(stream->indexoid));
		private = lappend(private, make_int4_const(stream->sortpos));
		private = lappend(private, make_float8_const(stream->reads));
		private = lappend(private, list_copy(stream->operators));
		private = lappend(private, list_copy(stream->collations));
		private = lappend(private, makeBoolConst(stream->backward, false));
		private = lappend(private, make_int4_const(stream->rank));
		exprs = lappend(exprs, copyObject(stream->keys));
		exprs = lappend(exprs, copyObject(stream->pred));
	}

	cscan->custom_private = private;
	cscan->custom_exprs = exprs;

#ifdef USE_ASSERT_CHECKING
	/* custom_private must survive a copy and a write-out and read-back */
	{
		List	   *read = (List *) stringToNode(nodeToString(private));
		List	   *copy = copyObject(read);

		Assert(equal(copy, private));
	}
#endif
}

static Datum
next_datum(List *list, int *pos)
{
	return list_nth_node(Const, list, (*pos)++)->constvalue;
}

static List *
next_oids(List *list, int *pos)
{
	List	   *oids = list_nth(list, (*pos)++);

	Assert(oids == NIL || IsA(oids, OidList));
	return oids;
}

/* Read back what form_plan_info wrote. */
IntersectPlanInfo *
lf_deform_plan_info(CustomScan *cscan)
{
	List	   *private = cscan->custom_private;
	List	   *exprs = cscan->custom_exprs;
	IntersectPlanInfo *info;
	bool		descending;
	Oid			sort_type;
	Oid			sort_opfamily;
	Oid			sort_collation;
	bool		nulls_first;
	bool		notnull;
	int			nstreams;
	int			pos = 0;
	int			epos = 0;

	descending = DatumGetBool(next_datum(private, &pos));
	sort_type = DatumGetObjectId(next_datum(private, &pos));
	sort_opfamily = DatumGetObjectId(next_datum(private, &pos));
	sort_collation = DatumGetObjectId(next_datum(private, &pos));
	nulls_first = DatumGetBool(next_datum(private, &pos));
	notnull = DatumGetBool(next_datum(private, &pos));
	nstreams = DatumGetInt32(next_datum(private, &pos));

	info = palloc0(IntersectPlanInfoSize(nstreams));
	info->descending = descending;
	info->sort_type = sort_type;
	info->sort_opfamily = sort_opfamily;
	info->sort_collation = sort_collation;
	info->nulls_first = nulls_first;
	info->notnull = notnull;
	info->nstreams = nstreams;
	for (int i = 0; i < nstreams; i++)
	{
		IntersectStreamInfo *stream = &info->streams[i];

		stream->indexoid = DatumGetObjectId(next_datum(private, &pos));
		stream->sortpos = DatumGetInt32(next_datum(private, &pos));
		stream->reads = DatumGetFloat8(next_datum(private, &pos));
		stream->operators = next_oids(private, &pos);
		stream->collations = next_oids(private, &pos);
		stream->backward = DatumGetBool(next_datum(private, &pos));
		stream->rank = DatumGetInt32(next_datum(private, &pos));
		stream->keys = list_nth(exprs, epos++);
		stream->pred = list_nth(exprs, epos++);
	}
	Assert(pos == list_length(private));
	Assert(epos == list_length(exprs));

	return info;
}

/*
 * lf_node_quals
 *		The clauses the node still evaluates on a fetched row, as
 *		create_indexscan_plan computes qpqual; the cost model charges these.
 *		Clauses implied by an inner predicate stay for a target relation
 *		(EvalPlanQual), and those implied by the outer one always stay.
 */
List *
lf_node_quals(PlannerInfo *root, RelOptInfo *rel, IndexOptInfo **indexes,
			  List **exprs, int nstreams, List *clauses)
{
	bool		is_target_rel;
	List	   *qpqual = NIL;
	ListCell   *lc;

	is_target_rel = (bms_is_member(rel->relid, root->all_result_relids) ||
					 get_plan_rowmark(root->rowMarks, rel->relid) != NULL);

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
		bool		enforced = false;

		if (rinfo->pseudoconstant)
			continue;
		for (int i = 0; i < nstreams && !enforced; i++)
		{
			List	   *indpred = i > 0 ? indexes[i]->indpred : NIL;

			if (is_candidate_equality(rinfo, rel->relid, indexes[i], exprs[i]))
				enforced = true;
			else if (!is_target_rel && indpred != NIL &&
					 !contain_mutable_functions((Node *) rinfo->clause) &&
					 predicate_implied_by(list_make1(rinfo->clause), indpred,
										  false))
				enforced = true;
		}
		if (!enforced)
			qpqual = lappend(qpqual, rinfo);
	}

	return qpqual;
}

static List *
intersect_scan_qual(PlannerInfo *root, RelOptInfo *rel, IntersectPlanInfo *info,
					List *clauses)
{
	IndexOptInfo *indexes[INTERSECT_MAX_STREAMS];
	List	   *exprs[INTERSECT_MAX_STREAMS];

	for (int i = 0; i < info->nstreams; i++)
	{
		indexes[i] = find_index_info(rel, info->streams[i].indexoid);
		exprs[i] = info->streams[i].keys;
	}

	return extract_actual_clauses(lf_node_quals(root, rel, indexes, exprs,
												info->nstreams, clauses),
								  false);
}

/*
 * intersect_plan_path
 *		PlanCustomPath callback.  The index OIDs need no relationOids entry:
 *		an index change invalidates its table's relcache, as for IndexScan.
 */
static Plan *
intersect_plan_path(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *tlist, List *clauses, List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);
	IntersectPlanInfo *info = ((IntersectPath *) best_path)->info;
	List	   *exprs = best_path->custom_private;

	for (int i = 0; i < info->nstreams; i++)
	{
		info->streams[i].keys = list_nth(exprs, 2 * i);
		info->streams[i].pred = list_nth(exprs, 2 * i + 1);
	}

	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = intersect_scan_qual(root, rel, info, clauses);
	cscan->scan.scanrelid = rel->relid;
	cscan->flags = best_path->flags;
	form_plan_info(info, cscan);
	cscan->custom_scan_tlist = NIL;
	cscan->methods = &lf_scan_methods;

	return &cscan->scan.plan;
}

static List *
intersect_reparameterize(PlannerInfo *root, List *custom_private,
						 RelOptInfo *child_rel)
{
	return (List *) adjust_appendrel_attrs_multilevel(root,
													  (Node *) custom_private,
													  child_rel,
													  child_rel->top_parent);
}

void
lf_planner_init(void)
{
	prev_set_rel_pathlist_hook = set_rel_pathlist_hook;
	set_rel_pathlist_hook = intersect_set_rel_pathlist;
}
