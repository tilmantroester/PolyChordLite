#include <Python.h>
#include "interfaces.h"
#include <iostream>

/* Docstrings */
static char module_docstring[] =
    "PyPolyChord: This module provides a Python interface to PolyChord.";
static char run_docstring[] =
    "Runs PyPolyChord";


/* Available functions */
static PyObject *run_PyPolyChord(PyObject *self, PyObject *args);


/* Module interface */
static PyMethodDef module_methods[] = {
    {"run", run_PyPolyChord, METH_VARARGS, run_docstring},
    {NULL, NULL, 0, NULL}
};


/* Initialize the module */
PyMODINIT_FUNC init_PyPolyChord(void)
{
    Py_InitModule3("_PyPolyChord", module_methods, module_docstring);
}


/* Convert from C array to Python list */
void convert_list(double* array, PyObject* list) {
    for (int i=0; i<PyList_Size(list); i++) 
        PyList_SET_ITEM(list, i, PyFloat_FromDouble(array[i]));
}

/* Convert from Python list to C array */
void convert_list(PyObject* list, double* array) {
    for (int i=0; i<PyList_Size(list); i++) 
        array[i] = PyFloat_AsDouble(PyList_GET_ITEM(list, i));
}

/* Callback to the likelihood and prior */
static PyObject *python_loglikelihood = NULL;

double loglikelihood(double* theta, int nDims, double* phi, int nDerived)
{
    /* Create a python version of theta */
    PyObject* list_theta = PyList_New(nDims);
    convert_list(theta,list_theta);

    /* Create a python version of phi */
    PyObject* list_phi = PyList_New(nDerived);
    convert_list(phi,list_phi);

    /* Compute the likelihood and phi from theta  */
    PyObject* pylogL = PyObject_CallFunctionObjArgs(python_loglikelihood,list_theta,list_phi,NULL);

    /* Convert the python answer back to a C double */
    double logL = PyFloat_AsDouble(pylogL);

    /* Garbage collect */
    Py_DECREF(list_theta);
    Py_DECREF(list_phi);
    Py_DECREF(pylogL);

    return logL;
}

static PyObject *python_prior = NULL;

void prior(double* cube, double* theta, int nDims)
{
    /* create a python version of cube */
    PyObject* list_cube = PyList_New(nDims);
    convert_list(cube,list_cube);

    /* Compute theta from the prior */
    PyObject* list_theta = PyObject_CallFunctionObjArgs(python_prior,list_cube,NULL);

    /* Convert the python answer back to a C array */
    convert_list(list_theta,theta);

    /* Garbage collect */
    Py_DECREF(list_cube);
    Py_DECREF(list_theta);
}

/* Function to run PyPolyChord */
static PyObject *run_PyPolyChord(PyObject *self, PyObject *args)
{
    /* Inputs to PolyChord in the order that they are passed to python */
    int nDims;
    int nDerived;
    int nlive;
    int num_repeats;
    int do_clustering;
    int feedback;
    double precision_criterion;
    int max_ndead;
    double boost_posterior;
    int posteriors;
    int equals;
    int cluster_posteriors;
    int write_resume;
    int write_paramnames;
    int read_resume;
    int write_stats;
    int write_live;
    int write_dead;
    int update_files;
    char* base_dir;
    char* file_root;

    /* Parse the input tuple */ 
    if (!PyArg_ParseTuple(args, "OOiiiiiididiiiiiiiiiiss", &python_loglikelihood, &python_prior, &nDims, &nDerived, &nlive, &num_repeats, &do_clustering, &feedback, &precision_criterion, &max_ndead, &boost_posterior, &posteriors, &equals, &cluster_posteriors, &write_resume, &write_paramnames, &read_resume, &write_stats, &write_live, &write_dead, &update_files, &base_dir, &file_root))
        return NULL;

    /* Run PolyChord */
    polychord_c_interface( 
            loglikelihood, 
            prior, 
            nlive, 
            num_repeats,
            do_clustering,
            feedback,
            precision_criterion,
            max_ndead,
            boost_posterior,
            posteriors,
            equals,
            cluster_posteriors,
            write_resume,
            write_paramnames,
            read_resume,
            write_stats,
            write_live,
            write_dead,
            update_files,
            nDims,
            nDerived,
            base_dir,
            file_root);

    /* Return None */
    PyObject *ret = Py_None;
    Py_INCREF(Py_None);
    return ret;
}
